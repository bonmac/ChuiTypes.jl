# The runtime's bounded queue (ADR-0002 §4, ADR-0003 §3; phase-4 spec §4).

"""
    QueueClosed()

The expected error (`Fail(QueueClosed())`) of [`offer`](@ref) on a closed [`Queue`](@ref) and of
[`receive`](@ref) on a closed, drained one.
"""
struct QueueClosed <: Exception end
Base.showerror(io::IO, ::QueueClosed) = print(io, "QueueClosed: the queue is closed")

"""
    Queue{T}(capacity)

A bounded FIFO queue for fibers (ADR-0002 §4). [`offer`](@ref)`(q, x)` waits while the queue is
full and [`receive`](@ref)`(q)` while it is empty; both waits end early on the **caller's own
cancellation**, so a cancelled producer wakes without closing a queue other fibers share. A
blocked `offer` is the backpressure of streams (ADR-0003 §3). `close(q)` makes later offers fail
with `Fail(QueueClosed())`; receivers drain what is queued, then fail the same way.

Thread-safe. In test mode every wait is a parked runtime primitive, so virtual time moves.
"""
mutable struct Queue{T}
    lock::ReentrantLock
    items::Vector{T}
    capacity::Int
    closed::Bool
    takers::Vector{_Waiter}
    putters::Vector{_Waiter}
    function Queue{T}(capacity::Integer) where {T}
        capacity >= 1 || throw(ArgumentError("a Queue's capacity must be at least 1, got $capacity"))
        return new{T}(ReentrantLock(), T[], Int(capacity), false, _Waiter[], _Waiter[])
    end
end

Base.show(io::IO, q::Queue{T}) where {T} = print(io, "Queue{", T, "}(", length(q), "/", q.capacity, q.closed ? ", closed)" : ")")
Base.length(q::Queue) = @lock q.lock length(q.items)
Base.isopen(q::Queue) = @lock q.lock !q.closed

# Fire and clear every waiter in `ws` (called with the lock held: firing only notifies).
function _wakeall!(ws::Vector{_Waiter})
    for w in ws
        _fire!(w)
    end
    empty!(ws)
    return nothing
end

function Base.close(q::Queue)
    @lock q.lock begin
        q.closed = true
        _wakeall!(q.takers)
        _wakeall!(q.putters)
    end
    return nothing
end

"Add `x` if there is room (never blocks). Returns whether it was added (false when full or closed)."
function _tryput!(q::Queue, x)
    return @lock q.lock begin
        if q.closed || length(q.items) >= q.capacity
            false
        else
            push!(q.items, x)
            _wakeall!(q.takers)
            true
        end
    end
end

"Remove the oldest item if any (never blocks): `(true, x)` or `(false, nothing)`."
function _trytake!(q::Queue)
    return @lock q.lock begin
        if isempty(q.items)
            (false, nothing)
        else
            x = popfirst!(q.items)
            _wakeall!(q.putters)
            (true, x)
        end
    end
end

# A timer that fires `w` at clock time `due`; returns a closer. Virtual clocks use their timer
# list (deterministic order), the real clock a Base `Timer`.
function _deadlinetimer(ctx::_Ctx, due::Float64, w::_Waiter)
    c = _clockof(ctx)
    if c isa VirtualClock
        tm = _addtimer!(c, due, w)
        return () -> begin
            @atomic tm.alive = false
            @lock c.lock filter!(x -> x !== tm, c.timers)
            nothing
        end
    end
    t = Timer(_ -> _fire!(w), max(0.0, due - _now(c)))
    return () -> close(t)
end

"""
    _put!(q, x, ctx) -> (ok, nothing | Cause)

Add `x`, waiting while the queue is full. Cancellable when `ctx` is interruptible:
`(false, Interrupted())`; `(false, Fail(QueueClosed()))` on a closed queue.
"""
function _put!(q::Queue, x, ctx::_Ctx)
    while true
        w = @lock q.lock begin
            if q.closed
                return (false, Fail(QueueClosed()))
            elseif length(q.items) < q.capacity
                push!(q.items, x)
                _wakeall!(q.takers)
                return (true, nothing)
            end
            w = _Waiter(ctx.rt)
            push!(q.putters, w)
            w
        end
        if !_park!(w, ctx.cancel, _interruptible(ctx))
            @lock q.lock filter!(y -> y !== w, q.putters)
            return (false, Interrupted())
        end
    end
    return
end

"""
    _take!(q, ctx, deadline = Inf) -> (ok, x | :timeout | Cause)

Remove the oldest item, waiting while the queue is empty, until `deadline` (a time on the
context's clock): `(true, :timeout)` then. Cancellable; `(false, Fail(QueueClosed()))` on a
closed, drained queue.
"""
function _take!(q::Queue, ctx::_Ctx, deadline::Float64 = Inf)
    while true
        w = @lock q.lock begin
            if !isempty(q.items)
                x = popfirst!(q.items)
                _wakeall!(q.putters)
                return (true, x)
            elseif q.closed
                return (false, Fail(QueueClosed()))
            end
            w = _Waiter(ctx.rt)
            push!(q.takers, w)
            w
        end
        if deadline < Inf && _now(_clockof(ctx)) >= deadline
            @lock q.lock filter!(y -> y !== w, q.takers)
            return (true, :timeout)
        end
        closer = deadline < Inf ? _deadlinetimer(ctx, deadline, w) : nothing
        ok = try
            _park!(w, ctx.cancel, _interruptible(ctx))
        finally
            closer === nothing || closer()
        end
        if !ok
            @lock q.lock filter!(y -> y !== w, q.takers)
            return (false, Interrupted())
        end
        if deadline < Inf && _now(_clockof(ctx)) >= deadline
            r = _trytake!(q)
            @lock q.lock filter!(y -> y !== w, q.takers)
            return r[1] ? r : (true, :timeout)
        end
    end
    return
end

# An effect from a context function returning (ok, value | Cause), the runtime primitive node.
_primeffect(::Type{E}, ::Type{A}, f) where {E, A} = _eff(E, A, _ENode(_N_PRIM, f))
# Internal, for tests: an effect that calls `f(ctx)` and succeeds with its result.
_ctxeffect(f) = _primeffect(Any, Any, ctx -> (true, f(ctx)))

"""
    offer(q::Queue, x) -> Effect

Add `x` to `q`, waiting (cancellably) while it is full. Fails with `Fail(QueueClosed())` if `q`
is closed.
"""
offer(q::Queue, x) = _primeffect(QueueClosed, Nothing, ctx -> _put!(q, x, ctx))

"""
    receive(q::Queue{T}) -> Effect{QueueClosed,T}

Remove and succeed with the oldest item of `q`, waiting (cancellably) while it is empty. Fails
with `Fail(QueueClosed())` once `q` is closed and drained.
"""
receive(q::Queue{T}) where {T} = _primeffect(QueueClosed, T, ctx -> _take!(q, ctx))
