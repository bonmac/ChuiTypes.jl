# Premise of ADR-0002 §10: fibers pinned to one thread (sticky @async), woken in seq order, plus a quiescence barrier.
function trial()
    out = Channel{Symbol}(8)
    evs = [Base.Event() for _ in 1:3]
    ts = [@async (wait(evs[k]); put!(out, (:a, :b, :c)[k])) for k in 1:3]
    yield()
    for e in evs
        notify(e)
    end
    while !all(istaskdone, ts)
        yield()
    end     # stand-in for "advance! returns when every fiber is parked"
    close(out)
    return collect(out)
end
orders = Dict{Any, Int}()
for _ in 1:500
    o = trial(); orders[o] = get(orders, o, 0) + 1
end
println(VERSION, " threads=", Threads.nthreads(), " orders: ", orders)
