# Interpreted ADT effect vs closure-composed effect: stack safety and call-site inference.
using Test
# --- (1) interpreted: abstract nodes, trampoline with explicit continuation stack
abstract type Node end
struct Pure <: Node
    v::Any
end
struct Suspend <: Node
    thunk::Any
end          # lazily builds the next node (for recursion)
struct Bind <: Node
    n::Node; k::Any
end
struct Eff{A}
    n::Node
end                       # phantom success type A
pure(::Type{A}, v) where {A} = Eff{A}(Pure(v))
flatmap(k, ::Type{B}, e::Eff) where {B} = Eff{B}(Bind(e.n, x -> k(x).n))
suspend(::Type{A}, f) where {A} = Eff{A}(Suspend(() -> f().n))
function interpret(n::Node)
    stack = Any[]
    while true
        if n isa Bind
            push!(stack, n.k); n = n.n
        elseif n isa Suspend
            n = n.thunk()
        else # Pure
            v = (n::Pure).v
            isempty(stack) && return v
            n = pop!(stack)(v)
        end
    end
    return
end
runeff(e::Eff{A}) where {A} = interpret(e.n)::A   # typeassert at the boundary
countdown(i) = i == 0 ? pure(Int, 0) : flatmap(x -> suspend(Int, () -> countdown(i - 1)), Int, pure(Int, i))
# --- (2) closure-composed: an effect is a function; bind nests calls
struct CEff{F}
    f::F
end
cpure(v) = CEff(() -> v)
cflatmap(k, e::CEff) = CEff(() -> k(e.f()).f())
crun(e::CEff) = e.f()
ccountdown(i) = i == 0 ? cpure(0) : cflatmap(x -> ccountdown(i - 1), cpure(i))

println("VERSION ", VERSION)
for n in (10_000, 1_000_000)
    r1 = try
        runeff(countdown(n))
    catch e
        typeof(e)
    end
    r2 = (n > 10_000 && get(ENV, "SKIP_DEEP_CLOSURE", "") == "1") ? :skipped : try
            crun(ccountdown(n))
    catch e
            typeof(e)
    end
    println("depth $n: interpreted -> $r1 | closure -> $r2")
end
f3(e) = runeff(e)
e = flatmap(x -> pure(Int, x + 1), Int, pure(Int, 1))
println("interpreted: return_types(runeff) = ", Base.return_types(f3, (typeof(e),)))
println("interpreted @inferred: ", (@inferred f3(e)))
c = cflatmap(x -> cpure(x + 1), cpure(1))
println("closure 2-step: return_types(crun) = ", Base.return_types(crun, (typeof(c),)))
println("closure type: ", typeof(c))
runeff(e); t = @elapsed for _ in 1:100_000
    runeff(e)
end
println("interpreted 2-step run: ", round(t / 100_000 * 1.0e9, digits = 1), " ns/run, allocs=", @allocated runeff(e))
crun(c); t = @elapsed for _ in 1:100_000
    crun(c)
end
println("closure 2-step run: ", round(t / 100_000 * 1.0e9, digits = 1), " ns/run, allocs=", @allocated crun(c))
