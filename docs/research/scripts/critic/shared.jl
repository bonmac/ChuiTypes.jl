# switchMap/merge with one shared bounded Base Channel: can we cancel ONE inner producer blocked in put!?
out = Channel{Vector{Int}}(1)
cancelA = Threads.Atomic{Bool}(false)
A = Threads.@spawn begin
    try
        for i in 1:10
            cancelA[] && return :sawtoken; put!(out, [i])
        end
        :done
    catch e
        typeof(e)
    end
end
B = Threads.@spawn try
    put!(out, [-1]); put!(out, [-2]); :done
catch e
    typeof(e)
end
sleep(0.3)
cancelA[] = true                      # cooperative token set: A is parked inside Base put!, never re-checks
sleep(0.5)
println(VERSION, " A done after token: ", istaskdone(A), "   (B done: ", istaskdone(B), ")")
close(out)                            # the only Base-safe wake-up: closes the channel for B as well
sleep(0.2)
println(VERSION, " after close: A -> ", fetch(A), ", B -> ", fetch(B))
# 1.10 silent end: for-loop over channel closed with an exception
ch = Channel{Int}(1); put!(ch, 1); close(ch, ErrorException("boom"))
r = try
    collect(ch)
catch e
    typeof(e)
end
println(VERSION, " collect(closed-with-ex channel) -> ", r)
