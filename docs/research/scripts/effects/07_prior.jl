# EFF: Julia prior art smoke test: CancellationTokens.jl and ConcurrentUtilities.try_with_timeout
using CancellationTokens, ConcurrentUtilities
println("VERSION = ", VERSION, "; CancellationTokens ", pkgversion(CancellationTokens), "; ConcurrentUtilities ", pkgversion(ConcurrentUtilities))
src = CancellationTokenSource()
tok = get_token(src)
t0 = time()
t = Threads.@spawn try
    sleep(10.0, tok)
    :slept
catch e
    e isa OperationCanceledException ? :canceled : rethrow()
end
sleep(0.1); cancel(src)
println("sleep(10, token) after cancel at 0.1s -> ", fetch(t), " in ", round(time() - t0; digits = 2), "s")
println("is_cancellation_requested = ", is_cancellation_requested(tok))
linked = CancellationTokenSource(get_token(CancellationTokenSource(0.05)))
t0 = time(); wait(get_token(linked)); println("linked timeout source fired after ", round(time() - t0; digits = 2), "s")

# try_with_timeout: does it stop the work task? (cooperative TimedOut flag only)
ran_on = Threads.Atomic{Bool}(false)
r = try
    ConcurrentUtilities.try_with_timeout(0.1) do timedout
        sleep(0.4); ran_on[] = true; :done
    end
catch e
    typeof(e)
end
println("try_with_timeout result: ", r)
sleep(0.6)
println("work kept running to completion after the timeout: ", ran_on[])
r2 = try
    ConcurrentUtilities.try_with_timeout(_ -> error("orig"), 1.0)
catch e
    e
end
println("try_with_timeout on error rethrows: ", typeof(r2), " ", r2 isa ErrorException ? r2.msg : "")
