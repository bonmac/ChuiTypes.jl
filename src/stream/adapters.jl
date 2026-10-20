# Channel ↔ stream adapters (ADR-0006 §5; phase-4 spec §9).

# How an exception from `take!` on a Base Channel ends a stream: `nothing` (closed normally) or
# `Fail(ex)` with the original exception (a `bind` failure is unwrapped).
function _channelend(ex)
    ex isa InvalidStateException && ex.state === :closed && return nothing
    ex isa TaskFailedException && return Fail(ex.task.exception)
    return Fail(ex)
end

struct _ChanSrc
    ch::Any
end
mutable struct _ChanP{T} <: _Puller
    ch::Channel{T}
    pending::Any            # nothing, or the end (`:end`) / Cause seen after a partial chunk
end
_open(s::_ChanSrc, ::_Ctx) = _ChanP(s.ch, nothing)

# Wait until `ch` is ready or closed, **without taking** (ADR-0006 §5): a helper task blocks in
# `wait(ch)` behind the `async` protocol in abandon mode, so a cancelled wait ends at once and
# leaves the helper (counted as an orphan) blocked until the channel has an item or closes.
function _waitready(ch::Channel, ctx::_Ctx)
    (isready(ch) || !isopen(ch)) && return (true, nothing)
    register = cb -> begin
        Threads.@spawn begin
            try
                wait(ch)
            catch
            end
            cb(Success(nothing))
        end
        nothing
    end
    return _async(ctx, register, nothing, true)
end

function _pull!(p::_ChanP{T}, ctx::_Ctx) where {T}
    if p.pending !== nothing
        r = p.pending
        p.pending = nothing
        return r === :end ? nothing : r
    end
    while true
        ok, c = _waitready(p.ch, ctx)
        ok || return c
        out = T[]
        while length(out) < _CHUNK && (isready(p.ch) || (isempty(out) && !isopen(p.ch)))
            x = try
                take!(p.ch)
            catch ex
                ex isa InterruptException && rethrow()
                e = _channelend(ex)
                isempty(out) && return e
                p.pending = e === nothing ? :end : e
                return out
            end
            push!(out, x)
        end
        isempty(out) || return out
    end
    return
end
_close!(::_ChanP, ::_Ctx) = nothing

"""
    fromchannel(ch::Channel{T}) -> Stream{T}

A **hot, single-consumer** stream of the items taken from `ch` (ADR-0006 §5): two runs split the
items. A pull waits until `ch` has an item, then takes every ready item (up to 1024) as one chunk.
`close(ch)` ends the stream after the buffered items; a channel closed with an exception (also
through `bind`) fails it with `Fail(ex)`, the original exception.

Cancelling a run while the channel is empty leaves a helper task blocked in `wait(ch)` until the
channel gets an item or closes; it takes nothing, so no item is lost, and it is counted in
[`ChuiTypes.orphans`](@ref) (one per cancelled wait). In test mode the helper is outside work:
virtual time may advance while it waits.
"""
fromchannel(ch::Channel{T}) where {T} = _stream(T, _ChanSrc(ch))

"""
    tochannel(s::Stream{T}; size = 0) -> Channel{T}

Run `s` in a new root fiber (real time) that `put!`s each element into a new `Channel{T}(size)`,
then closes it, or closes it with the run's exception (as [`run`](@ref) would throw it) on a
failure. **Closing the channel from the consumer side cancels that fiber** (ADR-0006 §5): a
`put!` on the closed channel stops it at once, and a timer that checks the channel every 10 ms
interrupts it while it waits upstream. `T` is the stream's advisory element type.
"""
function tochannel(s::Stream{T}; size::Integer = 0) where {T}
    ch = Channel{T}(size)
    f = start(runforeach(x -> put!(ch, x), s))
    watcher = Timer(0.01; interval = 0.01) do t
        if !isopen(ch)
            interrupt!(f)
            close(t)
        elseif _isdone(f)
            close(t)
        end
    end
    Threads.@spawn begin
        wait(f)
        close(watcher)
        x = something(f.exit)
        if isopen(ch)
            succeeded(x) ? close(ch) : close(ch, _exception(something(x.c)))
        end
    end
    return ch
end
