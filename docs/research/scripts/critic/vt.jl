# Virtual clock + real Tasks: wake two sleeping fibers due at the same virtual instant, in seq order (FIFO),
# the way an `advance!` that only "fires due timers" would. Do outputs follow seq order, and are they visible when advance! returns?
function trial()
    out = Channel{Symbol}(8)
    evs = [Base.Event() for _ in 1:2]               # fiber k sleeps on virtual time 10 (seq k)
    ts = [Threads.@spawn (wait(evs[k]); put!(out, k == 1 ? :first : :second)) for k in 1:2]
    sleep(0.01)
    for e in evs
        notify(e)
    end                    # advance!(clock, 10): fire seq 1 then seq 2
    seen_at_return = Base.n_avail(out)              # what an `expect` right after advance! would see
    foreach(wait, ts); close(out)
    return (collect(out), seen_at_return)
end
orders = Dict{Any, Int}(); vis = Dict{Int, Int}()
for _ in 1:200
    o, s = trial(); orders[o] = get(orders, o, 0) + 1; vis[s] = get(vis, s, 0) + 1
end
println(VERSION, " threads=", Threads.nthreads(), " orders: ", orders, "  items visible when advance! returned: ", vis)
