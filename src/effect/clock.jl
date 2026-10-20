# The clock service and test mode (ADR-0002 §9, §10; spec §9).

_clockof(ctx::_Ctx) = _lookup(ctx.env, AbstractClock)[2]

_now(::RealClock) = time()
_now(c::VirtualClock) = @lock c.lock c.now

# Wait `d` seconds on `clock`; `(true, nothing)`, or `(false, Interrupted())` if cancelled first.
function _sleep(::RealClock, d::Float64, ctx::_Ctx)
    d <= 0 && return (true, nothing)
    w = _Waiter(ctx.rt)
    t = Timer(_ -> _fire!(w), d)
    try
        return _park!(w, ctx.cancel, _interruptible(ctx)) ? (true, nothing) : (false, Interrupted())
    finally
        close(t)
    end
end

function _addtimer!(c::VirtualClock, due::Float64, w::_Waiter, seq::Int = 0)
    return @lock c.lock begin
        if seq == 0
            c.seq += 1
            seq = c.seq
        end
        tm = _VTimer(due, seq, w, true)
        i = searchsortedlast(c.timers, tm; by = x -> (x.due, x.seq)) + 1
        insert!(c.timers, i, tm)
        tm
    end
end

function _sleep(c::VirtualClock, d::Float64, ctx::_Ctx)
    d <= 0 && return (true, nothing)
    w = _Waiter(ctx.rt)
    tm = _addtimer!(c, _now(c) + d, w)
    ok = _park!(w, ctx.cancel, _interruptible(ctx))
    if !ok
        @atomic tm.alive = false
        @lock c.lock filter!(x -> x !== tm, c.timers)
        return (false, Interrupted())
    end
    return (true, nothing)
end

# Reserve `n` consecutive timer sequence numbers now: timers created later with them sort as if
# they had been scheduled at this moment (marble sources, phase-4 spec §13).
function _reserveseq!(c::VirtualClock, n::Int)
    return @lock c.lock begin
        s = c.seq + 1
        c.seq += max(n, 1)
        s
    end
end

# Wait until clock time `due`; with a VirtualClock and `seq > 0`, the timer uses that reserved
# sequence number. `(true, nothing)` or `(false, Interrupted())`.
function _sleepuntil(ctx::_Ctx, due::Float64, seq::Int = 0)
    c = _clockof(ctx)
    c isa VirtualClock || return _sleep(c, due - _now(c), ctx)
    _now(c) >= due && return (true, nothing)
    w = _Waiter(ctx.rt)
    tm = _addtimer!(c, due, w, seq)
    ok = _park!(w, ctx.cancel, _interruptible(ctx))
    if !ok
        @atomic tm.alive = false
        @lock c.lock filter!(x -> x !== tm, c.timers)
        return (false, Interrupted())
    end
    return (true, nothing)
end

"""
    delay(d::Real) -> Effect{Union{},Nothing}

Wait `d` seconds on the environment's clock (`RealClock()` unless a clock is provided; a
`VirtualClock` in test mode). Cancellable.
"""
delay(d::Real) = (s = Float64(d); _eff(Union{}, Nothing, _ENode(_N_PRIM, ctx -> _sleep(_clockof(ctx), s, ctx))))

"""
    clocktime() -> Effect{Union{},Float64}

The environment clock's time in seconds: `time()` for `RealClock()`, the virtual time for a
`VirtualClock`.
"""
clocktime() = _eff(Union{}, Float64, _ENode(_N_PRIM, ctx -> (true, _now(_clockof(ctx)))))

# ---- Test mode ------------------------------------------------------------------------------------

_quiet(c::VirtualClock) = @lock c.lock c.live == c.parked

# Yield until every live test-mode fiber is parked in a runtime primitive (or there are none).
function _quiesce(c::VirtualClock, timeout::Float64)
    t0 = time()
    while true
        yield()
        if _quiet(c)
            # A heuristic second look: a fiber woken by the last one may only now be runnable.
            # Wakers uncount a parked fiber at once, so this guards only against a scheduler
            # that has not yet run a just-scheduled task; it is not a proof of quiescence.
            yield()
            _quiet(c) && return nothing
        end
        if time() - t0 > timeout
            busy = @lock c.lock [t for t in c.tasks if !istaskdone(t)]
            live, parked = @lock c.lock (c.live, c.parked)
            error(
                "advance!: test mode did not become quiescent within $(timeout) s: $(live) live " *
                    "fibers, $(parked) parked in runtime primitives. A fiber blocked in a Base wait " *
                    "(a Channel, `sleep`, a lock) never parks. Live tasks: $(busy)"
            )
        end
    end
    return
end

function _popdue!(c::VirtualClock, limit::Float64)
    return @lock c.lock begin
        while !isempty(c.timers) && !(@atomic c.timers[1].alive)
            popfirst!(c.timers)
        end
        if isempty(c.timers) || c.timers[1].due > limit
            nothing
        else
            tm = popfirst!(c.timers)
            c.now = max(c.now, tm.due)
            tm
        end
    end
end

"""
    advance!(clock::VirtualClock, d::Real; timeout = 10.0) -> nothing

Move test-mode time forward by `d` seconds (ADR-0002 §10). First wait until every live
test-mode fiber is parked in a runtime primitive; then fire the timers due by `now + d` one at a
time, in `(due time, scheduling order)` order, each time setting the clock to its due time and
waiting for quiescence again; finally set the clock to `now + d`.

Call it from a task on the thread that started the test-mode fibers. If the fibers do not
become quiescent within `timeout` wall-clock seconds (a fiber blocked in a Base wait never
parks), it throws an error naming the live tasks.
"""
function advance!(c::VirtualClock, d::Real; timeout::Real = 10.0)
    to = Float64(timeout)
    target = _now(c) + Float64(d)
    _quiesce(c, to)
    while true
        tm = _popdue!(c, target)
        tm === nothing && break
        _fire!(tm.waiter::_Waiter)
        _quiesce(c, to)
    end
    @lock c.lock (c.now = max(c.now, target))
    _quiesce(c, to)
    return nothing
end

"""
    runtest(eff; clock = VirtualClock(), timeout = 10.0)

Run `eff` in **test mode** (ADR-0002 §10) and return its value or throw, like [`run`](@ref).
Every fiber is a sticky task on the caller's thread and every `delay` uses `clock`. Whenever all
fibers are parked, time jumps to the next due timer, so a program that sleeps for an hour runs at
once and deterministically. Same-instant wake-ups run in scheduling order; this order is
guaranteed only in test mode. With no timer due, no outside progress within `timeout` seconds and
the root not done, it interrupts the root and throws (deadlock).
"""
function runtest(e::Effect; clock::VirtualClock = VirtualClock(), timeout::Real = 10.0)
    to = Float64(timeout)
    f = start(e; clock)
    while true
        _quiesce(clock, to)
        _isdone(f) && break
        tm = _popdue!(clock, Inf)
        if tm === nothing
            # Outside work (a foreign task, an `async` callback) may still wake a fiber.
            t0 = time()
            while _quiet(clock) && !_isdone(f) && time() - t0 < to
                sleep(0.001)
            end
            _isdone(f) && break
            _quiet(clock) || continue
            # Best effort: interrupt the root so its finalizers run and its fibers end (a
            # masked wait that nothing completes still stays parked).
            # The cleanup gets its own bound: the caller's `timeout` may be short.
            interrupt!(f)
            t1 = time()
            while !_isdone(f) && time() - t1 < max(to, 10.0)
                yield()
                _quiet(clock) && sleep(0.001)
            end
            error("runtest: deadlock: the root fiber is not done, every fiber is parked and no timer is due (at time $(_now(clock))); the root was interrupted")
        end
        _fire!(tm.waiter::_Waiter)
    end
    return fetch(f)
end
