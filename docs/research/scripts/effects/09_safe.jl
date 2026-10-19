# EFF: safer cancellation delivery: wake the waiter through what it waits on, not throwto
println("VERSION = ", VERSION, "  nthreads = ", Threads.nthreads()); flush(stdout)
struct Cancelled <: Exception end

# (a) after throwto into sleep(0.3), does the Timer later try to reschedule the dead task?
started = Base.Event()
t = @async (notify(started); sleep(0.3); :woke)
wait(started); sleep(0.05)
schedule(t, Cancelled(); error = true)
try
    wait(t)
catch
end
sleep(0.6)   # past the original sleep deadline
println("(a) throwto into sleep(0.3): state = ", t.state, "; no stray error after timer deadline (see stderr above if any)"); flush(stdout)

# (b) notify(cond, exc; error=true): documented way to raise in waiters of a Condition
c = Threads.Condition()
t = Threads.@spawn lock(c) do;
    wait(c)
end
sleep(0.05)
lock(c) do;
    notify(c, Cancelled(); error = true)
end
try
    fetch(t)
catch e
    println("(b) notify(c, exc; error=true) -> waiter failed with ", typeof(e.task.exception))
end

# (c) close(ch, exc) wakes a blocked take! with that exception (stream end / cancel)
ch = Channel{Int}(0)
t = Threads.@spawn take!(ch)
sleep(0.05); close(ch, Cancelled())
try
    fetch(t)
catch e
    println("(c) close(ch, exc) -> take! threw ", typeof(e.task.exception))
end
ch2 = Channel{Int}(0); t = Threads.@spawn take!(ch2); sleep(0.05); close(ch2)
try
    fetch(t)
catch e
    println("(c') close(ch) -> take! threw ", typeof(e.task.exception))
end
ch3 = Channel{Int}(2); put!(ch3, 1); close(ch3); println("(c'') iterate closed buffered channel collects: ", collect(ch3))

# (d) cooperative token checked at yield points: a CPU loop that polls a flag every N iterations
tok = Threads.Atomic{Bool}(false)
t = Threads.@spawn begin
    i = 0
    while true
        i += 1
        if i % 1024 == 0
            tok[] && throw(Cancelled())
            yield()
        end
    end
end
sleep(0.1); tok[] = true
try
    fetch(t)
catch e
    println("(d) polled token in CPU loop -> ", typeof(e.task.exception))
end

# (e) Channel(f; spawn=true): producer exception propagates to consumer on close (stream error channel)
ch = Channel{Int}(1; spawn = true) do c
    put!(c, 1); error("producer boom")
end
r = try
    collect(ch)
catch e
    e
end
println("(e) collect(Channel(f)) where f throws -> ", typeof(r), r isa TaskFailedException ? " wrapping " * repr(r.task.exception) : "")
