# RWS: candidate encodings for State (Reader and Writer have the same shape), phase 3.
# Candidate A: closure-specialised `State{F}` (SUM-12). Candidate B: an erased node tree with a
# declared state type `S`, run by a loop with an explicit continuation stack, in two node
# layouts (B1 abstract node types, B2 one concrete node with a tag). Stdlib only.
# Usage: julia --startup-file=no rws_encodings.jl [deep-closure]
println("VERSION = ", VERSION)

# ---- A: closure struct -------------------------------------------------------------------
struct CState{F}
    run::F
end
cpure(x) = CState(s -> (x, s))
cbind(k, m) = CState(s -> ((a, s2) = m.run(s); k(a).run(s2)))
cget() = CState(s -> (s, s))
cput(x) = CState(_ -> (nothing, x))

# ---- B1: abstract nodes ----------------------------------------------------------------------
abstract type Node end
struct NPure <: Node
    a::Any
end
struct NBind <: Node
    m::Node
    k::Any
end
struct NGet <: Node end
struct NPut <: Node
    s::Any
end
struct EState{S}
    node::Node
end
epure(::Type{S}, x) where {S} = EState{S}(NPure(x))
ebind(k, m::EState{S}) where {S} = EState{S}(NBind(m.node, k))
eget(::Type{S}) where {S} = EState{S}(NGet())
eput(x::S) where {S} = EState{S}(NPut(x))

function erun(m::EState{S}, s0) where {S}
    s::S = s0
    stack = Any[]
    cur = m.node
    while true
        local a
        if cur isa NBind
            push!(stack, cur.k)
            cur = cur.m
            continue
        elseif cur isa NPure
            a = cur.a
        elseif cur isa NGet
            a = s
        else
            s = (cur::NPut).s
            a = nothing
        end
        isempty(stack) && return (a, s)
        cur = (pop!(stack)(a)::EState{S}).node
    end
    return
end

# ---- B2: one concrete node with a tag ---------------------------------------------------------
struct TNode
    tag::UInt8          # 0 pure, 1 bind, 2 get, 3 put
    x::Any              # pure value / put state / bind's inner node
    k::Any              # bind's continuation
end
struct TState{S}
    node::TNode
end
tpure(::Type{S}, x) where {S} = TState{S}(TNode(0x00, x, nothing))
tbind(k, m::TState{S}) where {S} = TState{S}(TNode(0x01, m.node, k))
tget(::Type{S}) where {S} = TState{S}(TNode(0x02, nothing, nothing))
tput(x::S) where {S} = TState{S}(TNode(0x03, x, nothing))

function trun(m::TState{S}, s0) where {S}
    s::S = s0
    stack = Any[]
    cur = m.node
    while true
        local a
        t = cur.tag
        if t == 0x01
            push!(stack, cur.k)
            cur = cur.x::TNode
            continue
        elseif t == 0x00
            a = cur.x
        elseif t == 0x02
            a = s
        else
            s = cur.x::S
            a = nothing
        end
        isempty(stack) && return (a, s)
        cur = (pop!(stack)(a)::TState{S}).node
    end
    return
end

# a counter: get, put(s+1), n times; built left-nested (bind of bind of ...) and right-nested
incr_e = _ -> ebind(s -> eput(s + 1), eget(Int))
incr_t = _ -> tbind(s -> tput(s + 1), tget(Int))
left_e(n) = (
    m = epure(Int, nothing); for _ in 1:n
        m = ebind(incr_e, m)
    end; m
)
left_t(n) = (
    m = tpure(Int, nothing); for _ in 1:n
        m = tbind(incr_t, m)
    end; m
)
right_e(n) = n == 0 ? epure(Int, nothing) : ebind(_ -> right_e(n - 1), incr_e(nothing))
right_t(n) = n == 0 ? tpure(Int, nothing) : tbind(_ -> right_t(n - 1), incr_t(nothing))

# Results go to a global sink so the timed call cannot be optimised away (critic NIT 9).
const SINK = Any[nothing]
function timeit(f, reps)
    SINK[1] = f()
    best = Inf
    for _ in 1:reps
        t = time_ns()
        SINK[1] = f()
        best = min(best, (time_ns() - t) / 1.0e9)
    end
    return best
end

if get(ARGS, 1, "") == "deep-closure"
    # A at depth n, left-nested, run in its own process: build and run are timed separately, so
    # a hang shows which of the two it is in (the last line printed).
    for n in (10^2, 10^3, 2 * 10^3, 4 * 10^3, 10^4)
        t0 = time()
        m = cpure(nothing)
        for _ in 1:n
            m = cbind(_ -> cbind(s -> cput(s + 1), cget()), m)
        end
        println("A closure left depth $n: built in ", round(time() - t0; digits = 2), " s")
        flush(stdout)
        t0 = time()
        r = try
            m.run(0)[2]
        catch e
            typeof(e)
        end
        println("A closure left depth $n: run gave ", r, " in ", round(time() - t0; digits = 2), " s")
        flush(stdout)
    end
    exit()
end

# ---- Writer: the accumulator is threaded through the run (acc = combine(acc, w) per tell) -----
struct WNode
    tag::UInt8          # 0 pure, 1 bind, 2 tell
    x::Any
    k::Any
end
function wrun(node::WNode, combine, acc0)
    acc = acc0
    stack = Any[]
    cur = node
    while true
        local a
        if cur.tag == 0x01
            push!(stack, cur.k)
            cur = cur.x::WNode
            continue
        elseif cur.tag == 0x00
            a = cur.x
        else
            acc = combine(acc, cur.x)
            a = nothing
        end
        isempty(stack) && return (a, acc)
        cur = pop!(stack)(a)::WNode
    end
    return
end
wtell(w) = WNode(0x02, w, nothing)
wleft(n, w) = (
    m = WNode(0x00, nothing, nothing); for _ in 1:n
        m = WNode(0x01, m, _ -> wtell(w))
    end; m
)
for (name, combine, acc0, w) in (
        ("Writer Int sum", +, 0, 1),
        ("Writer Vector vcat (copies the log)", vcat, Int[], [1]),
        ("Writer Vector append! (in place, mutates the accumulator)", (a, b) -> append!(a, b), nothing, [1]),
    )
    for n in (10^3, 10^4)
        m = wleft(n, w)
        mk = acc0 === nothing ? (() -> Int[]) : (() -> acc0)
        t = timeit(() -> wrun(m, combine, mk()), 3)
        println("$name, $n tells: ", round(t / n * 1.0e9; digits = 1), " ns per tell")
    end
end

# ---- A: inference by depth (SUM-12 repeated) --------------------------------------------------
for d in 1:4
    m = cpure(1)
    for _ in 1:d
        m = cbind(x -> cpure(x + 1), m)
    end
    rt = Base.return_types(m.run, (Int,))
    println("A closure depth $d: run(::Int) -> ", rt)
end

# ---- B: inference of the run function ----------------------------------------------------------
println("B1 erun(::EState{Int}, ::Int) -> ", Base.return_types(erun, (EState{Int}, Int)))
println("B2 trun(::TState{Int}, ::Int) -> ", Base.return_types(trun, (TState{Int}, Int)))

# ---- B: correctness and stack safety at depth 10^6, both nestings ------------------------------
for (name, build, run) in (
        ("B1 left", left_e, erun), ("B1 right", right_e, erun),
        ("B2 left", left_t, trun), ("B2 right", right_t, trun),
    )
    n = 10^6
    m = build(n)
    r = run(m, 0)
    println("$name depth $n: final state = ", r[2])
    flush(stdout)
end

# ---- B: cost per bind (each increment is 2 binds plus get and put), best of 5 -------------------
for (name, build, run) in (("B1", left_e, erun), ("B2", left_t, trun))
    n = 10^5
    m = build(n)
    t = timeit(() -> run(m, 0), 5)
    alloc = (run(m, 0); @allocated run(m, 0))
    println("$name run of $n increments: ", round(t / (2n) * 1.0e9; digits = 1), " ns per bind, ", round(alloc / n; digits = 1), " B per increment")
end
for (name, build) in (("B1 build", left_e), ("B2 build", left_t))
    n = 10^5
    t = timeit(() -> build(n), 5)
    println("$name of $n increments: ", round(t / n * 1.0e9; digits = 1), " ns per increment")
end
# (No closure run timing: at small depth the compiler folds the whole chain, so it measures 0 ns.)
