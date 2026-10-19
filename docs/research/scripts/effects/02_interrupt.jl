# EFF: does schedule(t, exc; error=true) interrupt a task blocked in various waits?
# usage: julia -t 4 02_interrupt.jl <case>   (one case per process; a hang is reported by the watchdog)
println("VERSION = ", VERSION, "  nthreads = ", Threads.nthreads()); flush(stdout)
struct MyCancel <: Exception end
const CASE = ARGS[1]

function probe(name, body)
    started = Base.Event()
    t = @async begin
        notify(started)
        body()
        :completed_normally
    end
    wait(started)
    sleep(0.05)   # let it block
    schedule(t, MyCancel(); error = true)
    r = timedwait(() -> istaskdone(t), 2.0)
    if r === :timed_out
        println(rpad(name, 24), "NOT interrupted within 2s (state=", t.state, ")"); flush(stdout)
        return
    end
    try
        v = fetch(t)
        println(rpad(name, 24), "finished normally: ", v)
    catch e
        println(
            rpad(name, 24), "fetch threw ", typeof(e), "; t.exception = ", typeof(t.exception),
            "; e.task.exception === t.exception: ", e isa TaskFailedException && e.task.exception === t.exception
        )
    end
    return flush(stdout)
end

if CASE == "sleep"
    probe("sleep(10)", () -> sleep(10))
elseif CASE == "channel"
    ch = Channel{Int}(0); probe("take!(Channel)", () -> take!(ch))
elseif CASE == "condition"
    c = Condition(); probe("wait(Condition)", () -> wait(c))
elseif CASE == "event"
    ev = Base.Event(); probe("wait(Event)", () -> wait(ev))
elseif CASE == "fetch"
    other = @async sleep(10); probe("fetch(other task)", () -> fetch(other))
elseif CASE == "tcondition"
    tc = Threads.Condition(); probe("wait(Threads.Condition)", () -> lock(() -> wait(tc), tc))
elseif CASE == "cpu"
    # tight CPU loop without yield points, on another thread
    stop = Threads.Atomic{Bool}(false); started = Threads.Atomic{Bool}(false)
    t = Threads.@spawn begin
        started[] = true
        x = 0
        while !stop[]
            x += 1
        end
        x
    end
    while !started[]
        yield()
    end
    sleep(0.05)
    println("cpu: state before schedule = ", t.state); flush(stdout)
    try
        schedule(t, MyCancel(); error = true)
        println("cpu: schedule(t, exc; error=true) on a RUNNING task returned without error"); flush(stdout)
    catch e
        println("cpu: schedule on running task threw ", sprint(showerror, e)); flush(stdout)
    end
    sleep(0.5)
    println("cpu: after 0.5s istaskdone = ", istaskdone(t)); flush(stdout)
    stop[] = true
    sleep(0.2)
    println("cpu: after stop flag istaskdone = ", istaskdone(t), " state = ", t.state); flush(stdout)
elseif CASE == "unwrap"
    t = @async error("original boom")
    try
        fetch(t)
    catch e
        println("fetch(error task) threw: ", typeof(e))
        println("  e.task.exception: ", repr(e.task.exception))
        println("  t.exception === e.task.exception: ", t.exception === e.task.exception)
        println("  length(current_exceptions(t)): ", length(current_exceptions(t)))
        println("  first(current_exceptions(t)).exception: ", repr(first(current_exceptions(t)).exception))
    end
    t2 = @async error("w")
    try
        wait(t2)
    catch e
        println("wait(error task) threw: ", typeof(e))
    end
    println("istaskfailed(t2) = ", istaskfailed(t2))
    # cooperative: finally blocks run when the injected exception unwinds a waiting task
    fin = Ref(false); started = Base.Event()
    t3 = @async try
        notify(started); sleep(10)
    finally
        fin[] = true
    end
    wait(started); sleep(0.05)
    schedule(t3, MyCancel(); error = true); timedwait(() -> istaskdone(t3), 2.0)
    println("finally ran in interrupted task: ", fin[])
    # Base.throwto from another task
    println("Base.throwto signature methods: ", length(methods(Base.throwto)))
end
