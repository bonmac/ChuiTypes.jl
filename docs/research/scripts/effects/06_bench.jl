# EFF: cost of Task spawn+fetch vs plain call vs a tiny closure-interpreted effect (free-monad style)
using BenchmarkTools
println("VERSION = ", VERSION, "  nthreads = ", Threads.nthreads())

# --- tiny effect ADT + trampolined interpreter (abstract-typed nodes, like a ZIO-style IO) ---
abstract type Eff end
struct Succeed <: Eff
    v::Any
end
struct FlatMap <: Eff
    e::Eff; k::Any
end   # k :: Any -> Eff
succeed(v) = Succeed(v)
flatmap(k) = e -> FlatMap(e, k)

function run_eff(e::Eff)
    stack = Any[]
    cur::Eff = e
    while true
        if cur isa FlatMap
            push!(stack, cur.k); cur = cur.e
        else # Succeed
            v = (cur::Succeed).v
            isempty(stack) && return v
            cur = pop!(stack)(v)
        end
    end
    return
end

build(n) = (
    e = succeed(1); for _ in 1:n
        e = e |> flatmap(x -> succeed(x + 1))
    end; e
)
plain(n) = (
    x = 1; for _ in 1:n
        x = Base.inferencebarrier(x) + 1
    end; x
)
const E1000 = build(1000)
@assert run_eff(E1000) == 1001

inc(x) = x + 1
println("plain call inc(1):             ", @belapsed(inc($(Ref(1))[])) * 1.0e9, " ns")
println("plain loop 1000 (inferencebarrier): ", @belapsed(plain(1000)) * 1.0e6, " us")
println("run_eff(prebuilt 1000 flatMaps): ", @belapsed(run_eff($E1000)) * 1.0e6, " us")
println("build+run 1000 flatMaps:       ", @belapsed(run_eff(build(1000))) * 1.0e6, " us")
println("fetch(Threads.@spawn 1):       ", @belapsed(fetch(Threads.@spawn 1)) * 1.0e6, " us")
println("fetch(@async 1):               ", @belapsed(fetch(@async 1)) * 1.0e6, " us")
println(
    "1000 sequential spawn+fetch:   ", @belapsed(
        begin
            x = 1; for _ in 1:1000
                x = fetch(Threads.@spawn $inc(x))
            end; x
        end
    ) * 1.0e6, " us"
)
t = @benchmark fetch(Threads.@spawn 1)
println("spawn+fetch allocs/memory:     ", t.allocs, " allocs, ", t.memory, " bytes; median ", median(t).time / 1.0e3, " us")
t = @benchmark run_eff($E1000)
println("run_eff 1000 allocs/memory:    ", t.allocs, " allocs, ", t.memory, " bytes; median ", median(t).time / 1.0e3, " us")
println("Sys.CPU_THREADS = ", Sys.CPU_THREADS, "; loadavg = ", Sys.loadavg())
