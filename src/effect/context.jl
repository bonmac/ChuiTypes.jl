# Cancel states, waiters, clocks' bookkeeping, the fiber context and the ScopedValue bridge
# (ADR-0002 §4, §10, §11; spec §4, §5, §9, §12).

# ---- Counters (ADR-0002 §11) -----------------------------------------------------------------

const _LIVE = Threads.Atomic{Int}(0)
const _ORPHANS = Threads.Atomic{Int}(0)

"""
    ChuiTypes.livefibers() -> Int

The number of fibers (root runs, forks, `fromtask` thunks) started and not yet finished, in this
process. Stress tests check that it returns to its earlier value.
"""
livefibers() = _LIVE[]

"""
    ChuiTypes.orphans() -> Int

The number of abandoned pieces of outside work so far: `fromtask(t::Task)` effects cancelled
without a canceller (the task keeps running, ADR-0006 §2) and `async` effects that gave up after
their `grace` (ADR-0006 §1). It only grows.
"""
orphans() = _ORPHANS[]

# ---- Clocks (the types; operations are in clock.jl) ----------------------------------------------

"""
    ChuiTypes.AbstractClock

Supertype of the clocks the runtime reads through the environment ([`delay`](@ref),
[`clocktime`](@ref)). Provide one with [`provide`](@ref); the default is `RealClock()`.
"""
abstract type AbstractClock end

"""
    ChuiTypes.RealClock()

The wall clock: `clocktime()` is `time()` (seconds since the epoch), `delay` waits on a `Timer`.
"""
struct RealClock <: AbstractClock end

mutable struct _VTimer
    due::Float64
    seq::Int
    waiter::Any             # a _Waiter
    @atomic alive::Bool
end

"""
    VirtualClock()

A clock for **test mode** (ADR-0002 §10): time starts at `0.0` and moves only through
[`advance!`](@ref) (or automatically in [`runtest`](@ref)). It also counts the test-mode fibers
that are live and parked, so `advance!` can wait until every fiber is blocked in a runtime
primitive. Same-instant wake-ups run in the order their delays were scheduled.

Use one `VirtualClock` per test; it is not thread-safe beyond the single thread test mode uses.
"""
mutable struct VirtualClock <: AbstractClock
    lock::ReentrantLock
    now::Float64
    seq::Int
    timers::Vector{_VTimer}         # sorted by (due, seq)
    live::Int
    parked::Int
    tasks::Set{Task}                # live test-mode tasks, for diagnostics
end
VirtualClock() = VirtualClock(ReentrantLock(), 0.0, 0, _VTimer[], 0, 0, Set{Task}())

Base.show(io::IO, c::VirtualClock) = print(io, "VirtualClock(now = ", c.now, ")")

# Test-mode bookkeeping. `rt` is the context's VirtualClock in test mode, else `nothing`.
_rtlive!(::Nothing, _) = nothing
function _rtlive!(c::VirtualClock, d::Int)
    @lock c.lock (c.live += d)
    return nothing
end
_rtparked!(::Nothing, _) = nothing
function _rtparked!(c::VirtualClock, d::Int)
    @lock c.lock (c.parked += d)
    return nothing
end

# ---- Waiters ---------------------------------------------------------------------------------

# A one-shot wake-up: `fired` is set by its source; a cancel only notifies. `counted` is true while
# the waiter is counted as parked in test mode; whoever wakes it first uncounts it, so `advance!`
# never sees a woken-but-not-yet-running fiber as parked.
mutable struct _Waiter
    @atomic fired::Bool
    @atomic counted::Bool
    cond::Threads.Condition
    rt::Union{Nothing, VirtualClock}
end
_Waiter(rt) = _Waiter(false, false, Threads.Condition(), rt)

function _uncount!(w::_Waiter)
    if (@atomicswap w.counted = false)
        _rtparked!(w.rt, -1)
    end
    return nothing
end

"Fire `w` (its source is ready) and wake its task."
function _fire!(w::_Waiter)
    @atomic w.fired = true
    _uncount!(w)
    @lock w.cond notify(w.cond)
    return nothing
end

"Wake `w` without firing it (a cancel); the parked task re-checks its cancel state."
function _poke!(w::_Waiter)
    _uncount!(w)
    @lock w.cond notify(w.cond)
    return nothing
end

# ---- Cancel states ---------------------------------------------------------------------------

# A mutable, level-triggered cancel flag with a parent, children and parked waiters (spec §5).
# `cancel!` sets the flag on the state and every descendant and pokes their waiters.
mutable struct _CancelState
    @atomic cancelled::Bool
    lock::ReentrantLock
    parent::Union{Nothing, _CancelState}
    children::Set{_CancelState}
    waiters::Set{_Waiter}
end
_CancelState(parent = nothing) = _CancelState(false, ReentrantLock(), parent, Set{_CancelState}(), Set{_Waiter}())

_iscancelled(cs::_CancelState) = @atomic cs.cancelled

"A new cancel state under `parent`, cancelled at once if `parent` already is."
function _childcancel(parent::_CancelState)
    cs = _CancelState(parent)
    c = @lock parent.lock begin
        push!(parent.children, cs)
        _iscancelled(parent)
    end
    c && _cancel!(cs)
    return cs
end

"Remove `cs` from its parent's children (when its fiber or region ends)."
function _detach!(cs::_CancelState)
    p = cs.parent
    p === nothing && return nothing
    @lock p.lock delete!(p.children, cs)
    return nothing
end

function _cancel!(cs::_CancelState)
    (@atomicswap cs.cancelled = true) && return nothing
    ws, cs2 = @lock cs.lock (collect(cs.waiters), collect(cs.children))
    for w in ws
        _poke!(w)
    end
    for c in cs2
        _cancel!(c)
    end
    return nothing
end

"""
    _park!(w, cs, interruptible) -> Bool

Block the current task until `w` fires (`true`) or, when `interruptible`, until `cs` is
cancelled (`false`). Counts the task as parked in test mode while it waits.
"""
function _park!(w::_Waiter, cs::_CancelState, interruptible::Bool)
    (@atomic w.fired) && return true
    interruptible && _iscancelled(cs) && return false
    interruptible && @lock cs.lock push!(cs.waiters, w)
    return try
        lock(w.cond)
        try
            while true
                (@atomic w.fired) && return true
                interruptible && _iscancelled(cs) && return false
                if w.rt !== nothing && !(@atomicswap w.counted = true)
                    _rtparked!(w.rt, 1)
                end
                wait(w.cond)
            end
        finally
            unlock(w.cond)
        end
    finally
        _uncount!(w)
        interruptible && @lock cs.lock delete!(cs.waiters, w)
    end
end

# ---- Environment -----------------------------------------------------------------------------

# A persistent list of services, innermost first. The default clock is appended by `service`.
struct _Env
    head::Any
    tail::Union{Nothing, _Env}
end
const _EMPTYENV = nothing

function _lookup(env::Union{Nothing, _Env}, ::Type{S}) where {S}
    while env !== nothing
        env.head isa S && return (true, env.head)
        env = env.tail
    end
    RealClock() isa S && return (true, RealClock())
    return (false, nothing)
end

_extend(env, services) = foldr((s, acc) -> _Env(s, acc), services; init = env)

# ---- Scopes and the fiber context ------------------------------------------------------------

mutable struct _Scope
    lock::ReentrantLock
    cancel::_CancelState
    children::Set{Any}              # live child fibers
    failure::Union{Nothing, Cause}  # the first failure (a child's, or the body's)
    dropped::Vector{Cause}          # later failures
    finalizers::Vector{Any}         # acquirerelease releases: exit -> Effect, in order
end
_Scope(cs::_CancelState) = _Scope(ReentrantLock(), cs, Set{Any}(), nothing, Cause[], Any[])

# Interpreter-local state of one fiber (ADR-0002 §4). Immutable: regions make a new one and push a
# frame that restores the old one.
struct _Ctx
    cancel::_CancelState
    env::Union{Nothing, _Env}
    mask::Int
    scope::Union{Nothing, _Scope}
    rt::Union{Nothing, VirtualClock}
end
_withmask(c::_Ctx, m::Int) = _Ctx(c.cancel, c.env, m, c.scope, c.rt)
_withenv(c::_Ctx, env) = _Ctx(c.cancel, env, c.mask, c.scope, c.rt)

_interruptible(c::_Ctx) = c.mask == 0

# The bridge: set once around each `sync`/`attempt` call (one `with`), never per step.
const _CTX = ScopedValues.ScopedValue{Union{Nothing, _Ctx}}(nothing)

"""
    checkcancel()

Inside a [`sync`](@ref) (or a `fromtask` thunk), throw [`Cancelled`](@ref)`()` if the fiber
running it is cancelled and not masked; otherwise return `nothing`. Outside the runtime it does
nothing. This is how long-running opaque code cooperates with cancellation (ADR-0002 §4): the
runtime never interrupts a running Julia function.
"""
function checkcancel()
    c = _CTX[]
    c === nothing && return nothing
    _interruptible(c) && _iscancelled(c.cancel) && throw(Cancelled())
    return nothing
end
