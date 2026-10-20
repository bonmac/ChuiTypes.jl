# Hot sources: Subject (ADR-0003 §5; phase-4 spec §7). One lock per subject guards every
# subscriber buffer; waits are the runtime's cancellable `_park!`, and every change wakes all
# waiters of the other side (broadcast), which re-check under the lock.

const _POLICIES = (:block, :dropnewest, :dropoldest, :latest)

mutable struct _Sub{T}
    buf::Vector{T}
    waiters::Vector{_Waiter}
    gone::Bool
end

"""
    Subject{T}(; capacity = 1024, overflow = :block)

A hot source: [`publish`](@ref)`(subj, x)` delivers `x` to every current subscription
([`subscribe`](@ref)`(subj)`, a `Stream{T}` whose run registers when it opens and leaves when it
closes). Emissions with nobody subscribed are dropped (Rx `Subject`).

Each subscriber has its own buffer of `capacity` **elements**; `overflow` says what a publish
does when a buffer is full, per element: `:block` (wait, cancellably, for space: the slowest
subscriber paces the publisher), `:dropnewest` (drop the new element), `:dropoldest` (drop the
oldest buffered one) or `:latest` (replace the buffer with the new element). Under `:block`, a
consumer that publishes into its own full subject deadlocks: use `:dropnewest` there.

`close(subj)` ends every subscription after its buffered elements and `close(subj, ex)` fails
them with `Fail(ex)`; later subscriptions end (or fail) at once and later publishes do nothing.
A cancelled `publish` may have delivered to only some subscribers.
"""
mutable struct Subject{T}
    lock::ReentrantLock
    subs::Vector{_Sub{T}}
    capacity::Int
    overflow::Symbol
    closed::Bool
    cause::Union{Nothing, Cause}
    pubwaiters::Vector{_Waiter}
    function Subject{T}(; capacity::Integer = _CHUNK, overflow::Symbol = :block) where {T}
        capacity >= 1 || throw(ArgumentError("a Subject's capacity must be at least 1, got $capacity"))
        overflow in _POLICIES || throw(ArgumentError("overflow must be one of $(_POLICIES), got :$overflow"))
        return new{T}(ReentrantLock(), _Sub{T}[], Int(capacity), overflow, false, nothing, _Waiter[])
    end
end

Base.show(io::IO, s::Subject{T}) where {T} = print(io, "Subject{", T, "}(", s.overflow, s.closed ? ", closed)" : ")")
Base.isopen(s::Subject) = @lock s.lock !s.closed

function _closesubject!(s::Subject, c)
    @lock s.lock begin
        if !s.closed
            s.closed = true
            s.cause = c
        end
        for sub in s.subs
            _wakeall!(sub.waiters)
        end
        _wakeall!(s.pubwaiters)
    end
    return nothing
end
Base.close(s::Subject) = _closesubject!(s, nothing)
Base.close(s::Subject, ex) = _closesubject!(s, Fail(ex))

function _register!(s::Subject{T}) where {T}
    sub = _Sub{T}(T[], _Waiter[], false)
    @lock s.lock (s.closed || push!(s.subs, sub))
    return sub
end
function _unregister!(s::Subject, sub::_Sub)
    @lock s.lock begin
        sub.gone = true
        filter!(x -> x !== sub, s.subs)
        _wakeall!(s.pubwaiters)
    end
    return nothing
end
_buffered(sub::_Sub) = copy(sub.buf)

# Deliver `x` to the subscribers in `pending` that have room (or by policy); returns the ones
# still waiting for space (only under :block). Called with the lock held.
function _deliver!(s::Subject, pending, x)
    keep = similar(pending, 0)
    for sub in pending
        sub.gone && continue
        if length(sub.buf) < s.capacity
            push!(sub.buf, x)
        elseif s.overflow === :block
            push!(keep, sub)
            continue
        elseif s.overflow === :dropnewest
            continue
        elseif s.overflow === :dropoldest
            popfirst!(sub.buf)
            push!(sub.buf, x)
        else # :latest
            empty!(sub.buf)
            push!(sub.buf, x)
        end
        _wakeall!(sub.waiters)
    end
    return keep
end

function _publish(s::Subject, x, ctx::_Ctx)
    pending = @lock s.lock (s.closed ? nothing : copy(s.subs))
    pending === nothing && return (true, nothing)
    while true
        w = @lock s.lock begin
            s.closed && return (true, nothing)
            pending = _deliver!(s, pending, x)
            isempty(pending) && return (true, nothing)
            w = _Waiter(ctx.rt)
            push!(s.pubwaiters, w)
            w
        end
        if !_park!(w, ctx.cancel, _interruptible(ctx))
            @lock s.lock filter!(y -> y !== w, s.pubwaiters)
            return (false, Interrupted())
        end
    end
    return
end

"""
    publish(subj::Subject, x) -> Effect{Union{},Nothing}

Deliver `x` to every current subscriber of `subj` (see [`Subject`](@ref) for full buffers).
Does nothing after `close(subj)`.
"""
publish(s::Subject, x) = _primeffect(Union{}, Nothing, ctx -> _publish(s, x, ctx))

struct _SubjSrc
    subject::Any
end
mutable struct _SubjP{T} <: _Puller
    s::Subject{T}
    sub::_Sub{T}
    closed::Bool
end
_open(src::_SubjSrc, ::_Ctx) = (s = src.subject; _SubjP(s, _register!(s), false))
function _pull!(p::_SubjP{T}, ctx::_Ctx) where {T}
    s = p.s
    while true
        w = @lock s.lock begin
            sub = p.sub
            if !isempty(sub.buf)
                n = min(length(sub.buf), _CHUNK)
                chunk = sub.buf[1:n]
                deleteat!(sub.buf, 1:n)
                _wakeall!(s.pubwaiters)
                return chunk
            elseif s.closed || sub.gone
                return s.cause
            end
            w = _Waiter(ctx.rt)
            push!(sub.waiters, w)
            w
        end
        if !_park!(w, ctx.cancel, _interruptible(ctx))
            @lock s.lock filter!(y -> y !== w, p.sub.waiters)
            return Interrupted()
        end
    end
    return
end
function _close!(p::_SubjP, ::_Ctx)
    p.closed && return nothing
    p.closed = true
    _unregister!(p.s, p.sub)
    return nothing
end

"""
    subscribe(subj::Subject{T}) -> Stream{T}

The hot stream of `subj`'s publications from the moment a run opens it until the run closes it
or `subj` is closed. A pull takes every buffered element (up to 1024) as one chunk, so a hot
source never waits to fill a chunk.
"""
subscribe(s::Subject{T}) where {T} = _stream(T, _SubjSrc(s))
