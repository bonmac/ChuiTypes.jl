# EFF: building timeout on Timer / timedwait / Event; interrupting the loser
println("VERSION = ", VERSION, "  nthreads = ", Threads.nthreads())
struct TimeoutCancel <: Exception end

# timeout(f, secs): race the work task against a Timer; on timeout, throwto the work task
function timeout(f, secs)
    done = Base.Event()
    work = Threads.@spawn try
        f()
    finally
        notify(done)
    end
    timer = Timer(_ -> notify(done), secs)
    wait(done)
    close(timer)
    if istaskdone(work)
        return (:ok, fetch(work))
    else
        schedule(work, TimeoutCancel(); error = true)   # NOTE: only safe for a task that is waiting
        timedwait(() -> istaskdone(work), 1.0)
        return (:timed_out, istaskdone(work) ? typeof(work.exception) : :still_running)
    end
end
println("fast work: ", timeout(() -> (sleep(0.01); 42), 1.0))
t0 = time()
cleaned = Ref(false)
r = timeout(
    () -> try
        sleep(5)
    finally
        cleaned[] = true
    end, 0.2
)
println("slow work: ", r, " after ", round(time() - t0; digits = 2), "s; finally ran: ", cleaned[])

# timedwait semantics
t0 = time()
println("timedwait(false, 0.2) = ", timedwait(() -> false, 0.2), " in ", round(time() - t0; digits = 2), "s")
println("timedwait(true, 0.2)  = ", timedwait(() -> true, 0.2))
# Timer is closable and Event is reusable?
ev = Base.Event(); notify(ev); wait(ev); wait(ev); println("Event stays set after notify (non-autoreset): true")
if hasmethod(Base.Event, Tuple{Bool})
    ar = Base.Event(true); notify(ar); wait(ar)
    println("Event(autoreset=true) available; after one wait isset: ", ar.set)
else
    println("Event(autoreset) not available")
end
