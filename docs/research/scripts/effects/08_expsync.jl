# EFF: Base.Experimental.@sync is fail-fast but does not cancel siblings
println("VERSION = ", VERSION, "  nthreads = ", Threads.nthreads())
t0 = time(); sib_done = Threads.Atomic{Bool}(false)
try
    Base.Experimental.@sync begin
        Threads.@spawn (sleep(0.1); error("A boom"))
        Threads.@spawn (sleep(1.0); sib_done[] = true)
    end
catch e
    println("Experimental.@sync threw ", typeof(e), " after ", round(time() - t0; digits = 2), "s; sibling done yet: ", sib_done[])
end
sleep(1.2)
println("sibling ran to completion afterwards (not cancelled): ", sib_done[])
if isdefined(Base.Experimental, :wait_with_timeout)
    c = Threads.Condition()
    r = lock(c) do;
        Base.Experimental.wait_with_timeout(c; timeout = 0.1)
    end
    println("Experimental.wait_with_timeout(c; timeout=0.1) = ", r)
else
    println("Base.Experimental.wait_with_timeout: not defined")
end
