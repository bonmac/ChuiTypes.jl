# Time sources and time operators (ADR-0003 §9; phase-4 spec §6). All read the environment's
# clock, so they run on virtual time under `runtest`. An element's time is the time its chunk
# is pulled by the operator. Ties are decided by comparing times, never by timer order.

_clocknow(ctx::_Ctx) = _now(_clockof(ctx))

# ---- interval and timer -------------------------------------------------------------------------

struct _IntervalSrc
    d::Float64
end
mutable struct _IntervalP <: _Puller
    d::Float64
    t0::Float64
    k::Int
end
_open(s::_IntervalSrc, ctx::_Ctx) = _IntervalP(s.d, _clocknow(ctx), 0)
function _pull!(p::_IntervalP, ctx::_Ctx)
    ok, c = _sleepuntil(ctx, p.t0 + (p.k + 1) * p.d)
    ok || return c
    k = p.k
    p.k += 1
    return [k]
end
_close!(::_IntervalP, ::_Ctx) = nothing

"""
    interval(d) -> Stream{Int}

A cold, unbounded stream of `0, 1, 2, …`: element `k` at `(k + 1) * d` seconds after the run
subscribes, on the environment's clock (each a one-element chunk). Bound it with `take`.
"""
function interval(d::Real)
    d > 0 || throw(ArgumentError("interval: d must be positive, got $d"))
    return _stream(Int, _IntervalSrc(Float64(d)))
end

"""
    timer(d) -> Stream{Int}

A cold stream of one element, `0`, `d` seconds after the run subscribes, then the end.
"""
timer(d::Real) = Iterators.take(interval(d), 1)

# ---- throttle (no fiber) ------------------------------------------------------------------------

struct _ThrottleSrc
    src::Any
    d::Float64
end
mutable struct _ThrottleP <: _Puller
    up::Any
    d::Float64
    last::Float64
end
_open(s::_ThrottleSrc, ctx::_Ctx) = _ThrottleP(_sopen(s.src, ctx), s.d, -Inf)
function _pull!(p::_ThrottleP, ctx::_Ctx)
    while true
        r = _pull!(p.up, ctx)
        (r === nothing || r isa Cause) && return r
        now = _clocknow(ctx)
        if now >= p.last + p.d
            p.last = now
            return [first(r)]                    # one chunk is one instant: its first element
        end
    end
    return
end
_close!(p::_ThrottleP, ctx::_Ctx) = _close!(p.up, ctx)

"""
    throttle(s::Stream, d) -> Stream

Leading-edge throttle: an element passes if no element passed in the last `d` seconds; the
others are dropped. Ties: the elements of one chunk arrive at one instant, so only its first can
pass.
"""
throttle(s::Stream{T}, d::Real) where {T} = _stream(T, _ThrottleSrc(s.src, Float64(d)))

# ---- Pumped time operators: a lease pump for the input, timed takes in the consumer ----------------

mutable struct _TimedIn
    q::Queue{_Msg}
    fiber::Any
    pending::Union{Nothing, _Msg}
    closed::Bool
end
function _timedin(src, ctx::_Ctx)
    q = Queue{_Msg}(4)
    return _TimedIn(q, _forkpump(ctx, src, q, 1, true), nothing, false)
end
# The next message (a stashed one first), or `:timeout` at `deadline`, or a Cause.
function _next!(t::_TimedIn, ctx::_Ctx, deadline::Float64)
    if t.pending !== nothing
        m = t.pending
        t.pending = nothing
        return m
    end
    return _takemsg!(t.q, ctx, deadline)
end
function _closein!(t::_TimedIn, ctx::_Ctx)
    t.closed && return nothing
    t.closed = true
    _stopall!((t.fiber,), ctx)
    return nothing
end

# ---- debounce -----------------------------------------------------------------------------------

struct _DebounceSrc
    src::Any
    d::Float64
end
mutable struct _DebounceP <: _Puller
    in::_TimedIn
    d::Float64
    has::Bool
    kept::Any
    deadline::Float64
    ended::Bool
end
_open(s::_DebounceSrc, ctx::_Ctx) = _DebounceP(_timedin(s.src, ctx), s.d, false, nothing, Inf, false)
function _emitkept!(p::_DebounceP)
    p.has = false
    p.deadline = Inf
    x = p.kept
    p.kept = nothing
    return [x]
end
function _pull!(p::_DebounceP, ctx::_Ctx)
    p.ended && return nothing
    while true
        p.has && _clocknow(ctx) >= p.deadline && return _emitkept!(p)
        m = _next!(p.in, ctx, p.has ? p.deadline : Inf)
        m === :timeout && continue
        m isa Cause && return m
        if p.has && _clocknow(ctx) >= p.deadline        # the expiry first, at this instant
            p.in.pending = m
            return _emitkept!(p)
        end
        if m.kind == _K_CHUNK
            p.kept = last(m.val)
            p.has = true
            p.deadline = _clocknow(ctx) + p.d
        elseif m.kind == _K_DONE
            p.ended = true
            return p.has ? _emitkept!(p) : nothing
        else
            return m.val::Cause                          # a failure drops the kept element
        end
    end
    return
end
_close!(p::_DebounceP, ctx::_Ctx) = _closein!(p.in, ctx)

"""
    debounce(s::Stream, d) -> Stream

Emit an element only after `d` seconds without a newer one (Rx `debounceTime`). The end emits
the element still kept, then ends; a failure drops it. Ties are decided by time: when an arrival
and the deadline fall on the same instant, the kept element is emitted first. A chunk counts as
one arrival (its last element is kept).
"""
function debounce(s::Stream{T}, d::Real) where {T}
    d > 0 || throw(ArgumentError("debounce: d must be positive, got $d"))
    return _stream(T, _DebounceSrc(s.src, Float64(d)))
end

# ---- buffertime and windowtime --------------------------------------------------------------------

struct _BufTimeSrc
    src::Any
    d::Float64
end
mutable struct _BufTimeP <: _Puller
    in::_TimedIn
    d::Float64
    t0::Float64
    buf::Vector{Any}
    windowend::Float64
    ended::Bool
end
_open(s::_BufTimeSrc, ctx::_Ctx) = _BufTimeP(_timedin(s.src, ctx), s.d, _clocknow(ctx), Any[], Inf, false)
function _flush!(p::_BufTimeP)
    v = map(identity, p.buf)
    p.buf = Any[]
    p.windowend = Inf
    return [v]
end
function _pull!(p::_BufTimeP, ctx::_Ctx)
    p.ended && return nothing
    while true
        !isempty(p.buf) && _clocknow(ctx) >= p.windowend && return _flush!(p)
        m = _next!(p.in, ctx, isempty(p.buf) ? Inf : p.windowend)
        m === :timeout && continue
        m isa Cause && return m
        now = _clocknow(ctx)
        if !isempty(p.buf) && now >= p.windowend      # a boundary arrival opens the next window
            p.in.pending = m
            return _flush!(p)
        end
        if m.kind == _K_CHUNK
            if isempty(p.buf)                          # a timer only for a non-empty window
                k = floor((now - p.t0) / p.d)
                p.windowend = p.t0 + (k + 1) * p.d
            end
            append!(p.buf, m.val)
        elseif m.kind == _K_DONE
            p.ended = true
            return isempty(p.buf) ? nothing : _flush!(p)
        else
            return m.val::Cause
        end
    end
    return
end
_close!(p::_BufTimeP, ctx::_Ctx) = _closein!(p.in, ctx)

"""
    buffertime(s::Stream, d) -> Stream{Vector}

The elements of `s` grouped by time window `[t0 + k*d, t0 + (k+1)*d)` from the subscription
time `t0`, each non-empty window emitted at its end (empty windows are skipped, unlike Rx); at
the end, the partial window. An element exactly at a boundary belongs to the next window. An
idle input schedules no timers.
"""
function buffertime(s::Stream{T}, d::Real) where {T}
    d > 0 || throw(ArgumentError("buffertime: d must be positive, got $d"))
    return _stream(Vector{T}, _BufTimeSrc(s.src, Float64(d)))
end

"""
    windowtime(s::Stream, d) -> Stream{Stream}

Like [`buffertime`](@ref), with each window given as a finite `Stream` (buffered first; see
[`window`](@ref)).
"""
windowtime(s::Stream{T}, d::Real) where {T} = _fuse(Stream{T}, buffertime(s, d), U.Map(fromiter))
