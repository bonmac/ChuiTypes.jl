# Adapters to callbacks and Tasks (ADR-0006 §1–§4, ecosystem ADR-0013; spec §10).

# How an exception that crossed a Task boundary comes back (ADR-0006 §4): always a `Fail`.
function _fromexception(ex)
    ex isa TaskFailedException && (ex = ex.task.exception)
    ex isa EffectFailed && return Fail(ex.e)
    ex isa Cancelled && return Interrupted()
    return Fail(ex)
end

# Spawn outside work for a context: a non-sticky task in real mode, a sticky one in test mode.
function _spawnwork(body, rt)
    rt === nothing && return Threads.@spawn body()
    t = Task(body)
    t.sticky = true
    schedule(t)
    return t
end

# A timer that fires `w` after `d` seconds on the context's clock; returns a closer.
function _gracetimer(ctx::_Ctx, d::Float64, w::_Waiter)
    c = _clockof(ctx)
    if c isa VirtualClock
        tm = _addtimer!(c, _now(c) + d, w)
        return () -> (@atomic tm.alive = false; nothing)
    end
    t = Timer(_ -> _fire!(w), d)
    return () -> close(t)
end

# The canceller protocol of ADR-0006 §1. With `abandon`, a missing canceller means "end at once
# and count an orphan" (fromtask of a foreign Task, ADR-0006 §2).
function _async(ctx::_Ctx, register, grace, abandon::Bool)
    w = _Waiter(ctx.rt)                 # fired by the callback
    g = _Waiter(ctx.rt)                 # fired by the callback or the grace timer
    once = Threads.Atomic{Bool}(false)
    box = Ref{Any}(nothing)
    cb = x -> begin
        if !Threads.atomic_xchg!(once, true)
            box[] = x
            _fire!(w)
            _fire!(g)
        end
        return nothing
    end
    canceller = register(cb)
    if !_park!(w, ctx.cancel, _interruptible(ctx))
        if canceller === nothing && abandon
            Threads.atomic_add!(_ORPHANS, 1)
            return (false, Interrupted())
        end
        cerr = nothing
        if canceller !== nothing
            try
                canceller()
            catch ex
                cerr = Die(ex, catch_backtrace())
            end
        end
        if grace === nothing
            _park!(w, ctx.cancel, false)
        else
            close! = _gracetimer(ctx, Float64(grace), g)
            _park!(g, ctx.cancel, false)
            close!()
            if !(@atomic w.fired)
                Threads.atomic_add!(_ORPHANS, 1)
            end
        end
        c = Interrupted()
        return (false, cerr === nothing ? c : _suppress(c, cerr))
    end
    x = box[]
    x isa Exit || return (false, Die(ArgumentError("the async callback must be called with an Exit, got a $(typeof(x))")))
    return _asresult(x)
end

"""
    async(register; grace = nothing) -> Effect

The canceller primitive (ADR-0006 §1). Running it calls `register(cb)`, which starts outside work
and returns a **canceller** (a zero-argument function) or `nothing`; the work must later call
`cb(exit::Exit)` (`Success(x)` or `Failure(Fail(e))`) exactly once — `cb` is thread-safe, may be
called from any thread or `Timer`, may be called before `register` returns, and ignores every call
after the first.

On cancellation the runtime calls the canceller (for example to close a socket), then waits for
`cb`, masked. With `grace = nothing` it waits indefinitely: a canceller that never leads to `cb`
hangs the effect. With `grace = d` it gives up after `d` seconds, counts an orphan
([`ChuiTypes.orphans`](@ref)) and ends `Interrupted`.
"""
async(register; grace = nothing) = _eff(Any, Any, _ENode(_N_PRIM, ctx -> _async(ctx, register, grace, false)))

"""
    fromtask(t::Task; canceller = nothing) -> Effect{Exception,A}
    fromtask(f::Function) -> Effect{Exception,A}

**Task → effect** (ADR-0006 §2, ecosystem ADR-0013). Running `fromtask(t)` schedules `t` if it has
not started and waits for it; later runs see the same outcome. A failure is `Fail(ex)` with `ex`
the task's own exception object (`t.exception`), never the `TaskFailedException`.

Cancelling it runs `canceller()` if one was given, then waits for `t`. Without a canceller the
effect ends `Interrupted` at once and `t` is **abandoned**: it keeps running and is counted in
[`ChuiTypes.orphans`](@ref). A started Base task cannot be stopped from outside.

`fromtask(f)` runs `f()` in a new task as cooperative work under the effect's cancellation: inside
it, [`checkcancel`](@ref), `run` and the runtime primitives see the fiber's cancel state and
environment. Cancelling the effect cancels that work and waits for it.
"""
function fromtask(t::Task; canceller = nothing)
    register = ctx -> cb -> begin
        istaskstarted(t) || try
            schedule(t)
        catch
        end
        watch = () -> begin
            x = try
                Success(fetch(t))
            catch ex
                Failure(_fromexception(ex))
            end
            cb(x)
        end
        _spawnwork(watch, ctx.rt)
        return canceller
    end
    return _eff(Exception, Any, _ENode(_N_PRIM, ctx -> _async(ctx, register(ctx), nothing, true)))
end

function _fromthunk(ctx::_Ctx, f)
    cs = _childcancel(ctx.cancel)
    sub = _Ctx(cs, ctx.env, 0, nothing, ctx.rt)
    rt = ctx.rt
    register = cb -> begin
        Threads.atomic_add!(_LIVE, 1)
        _rtlive!(rt, 1)
        body = () -> begin
            x = try
                Success(ScopedValues.with(f, _CTX => sub))
            catch ex
                Failure(ex isa Cancelled && _iscancelled(cs) ? Interrupted() : _fromexception(ex))
            end
            cb(x)
            _detach!(cs)
            Threads.atomic_sub!(_LIVE, 1)
            if rt !== nothing
                @lock rt.lock begin
                    rt.live -= 1
                    delete!(rt.tasks, current_task())
                end
            end
            return nothing
        end
        t = _spawnwork(body, rt)
        rt === nothing || @lock rt.lock push!(rt.tasks, t)
        return () -> _cancel!(cs)
    end
    return _async(ctx, register, nothing, false)
end

fromtask(f::Function) = _eff(Exception, _ret(f), _ENode(_N_PRIM, ctx -> _fromthunk(ctx, f)))

"""
    totask(eff) -> Task

**Effect → Task** for Base interop (ADR-0006 §3): a started task that runs `eff` with [`run`](@ref).
Its `fetch` returns the value, or throws a `TaskFailedException` whose `task.exception` is the
original exception object (`===`), because Base's `fetch` always wraps. To get the original
thrown directly, or to cancel, use [`start`](@ref) and its [`Fiber`](@ref).
"""
totask(e::Effect) = Threads.@spawn run(e)
