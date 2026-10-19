# EFF: ScopedValue propagation into Threads.@spawn / @async / Channel-task children
println("VERSION = ", VERSION, "  nthreads = ", Threads.nthreads())
if isdefined(Base, :ScopedValues)
    using Base.ScopedValues
    println("using Base.ScopedValues")
else
    using ScopedValues
    println("using ScopedValues.jl ", pkgversion(ScopedValues))
end
const ENV_SV = ScopedValue(:root)
println("outside: ", ENV_SV[])
with(ENV_SV => :inner) do
    println("inside with: ", ENV_SV[])
    println("Threads.@spawn child: ", fetch(Threads.@spawn ENV_SV[]))
    println("@async child: ", fetch(@async ENV_SV[]))
    println("nested spawn: ", fetch(Threads.@spawn fetch(Threads.@spawn ENV_SV[])))
    ch = Channel{Symbol}(1; spawn = true) do c
        put!(c, ENV_SV[])
    end
    println("Channel(f; spawn=true) task: ", take!(ch))
    t = Task(() -> ENV_SV[]); schedule(t)
    println("Task(f) constructed inside with: ", fetch(t))
end
# a task created outside, run inside: sees the creator's scope
t = Task(() -> ENV_SV[])
with(ENV_SV => :late) do;
    schedule(t); println("Task created outside, scheduled inside with: ", fetch(t))
end
@with ENV_SV => :macro begin
    println("@with: ", ENV_SV[])
end
# timer callbacks
with(ENV_SV => :timer) do
    ev = Base.Event(); r = Ref{Any}()
    Timer(_ -> (r[] = ENV_SV[]; notify(ev)), 0.01); wait(ev)
    println("Timer callback: ", r[])
end
