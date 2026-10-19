names_ = [:interrupt, :interrupt!, :await, :start, :sync, :attempt, :runtest, :none, :timeout, :timeoutfail, :fork, :forkdaemon, :Effect, :Exit, :Cause, :Fiber, :Scope, :provide, :service, :MissingService, :uninterruptible, :interruptiblemask, :bracket, :acquirerelease, :checkcancel, :recurs, :spaced, :exponential, :jittered, :interval, :timer, :Stream, :scan, :concat, :drop, :buffer, :window, :debounce, :throttle, :switchmap, :mergemap, :withbatches, :runcollect, :runfold, :runforeach, :advance!, :VirtualClock, :Queue, :Option, :EffectFailed, :Cancelled, :fromtask, :totask, :fromchannel, :tochannel, :delay, :clocktime]
mods = Module[Base, Core]
for p in readdir(Sys.STDLIB)
    try
        m = Base.require(Base.PkgId(Base.identify_package(p).uuid, p)); push!(mods, m)
    catch
    end
end
for n in names_
    hits = [string(nameof(m)) for m in mods if isdefined(m, n) && Base.isexported(m, n)]
    isempty(hits) || println(rpad(n, 18), join(hits, ","))
end
println("loaded modules: ", length(mods))
