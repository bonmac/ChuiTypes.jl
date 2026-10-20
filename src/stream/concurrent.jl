# Concurrent operators (ADR-0003 §3, §4, §7; phase-4 spec §5): producer fibers ("pumps") put
# messages on a bounded Queue; the consumer's pull takes them. Errors travel as messages.

const _K_CHUNK = 0x01
const _K_DONE = 0x02
const _K_FAIL = 0x03
const _K_OUTERDONE = 0x04

struct _Msg
    tag::Int          # input index, or the switchmap generation
    kind::UInt8
    val::Any          # the chunk, the Cause, or the outer's count
end

# The effect of a fiber body running `f(ctx)`; its fiber ends `Success(nothing)` or interrupted.
_fiberbody(f) = _primeffect(Any, Nothing, ctx -> (f(ctx); (true, nothing)))

# Stop fibers: interrupt all, then await each, masked (the close order of spec §5).
function _stopall!(fs, ctx::_Ctx)
    for f in fs
        interrupt!(f)
    end
    for f in fs
        _awaitfiber(f, ctx.cancel, false, ctx.rt)
    end
    return nothing
end

# Wait (masked) until `ctx` is cancelled: the lease park of a finished pump (spec §5).
function _parkuntilcancel(ctx::_Ctx)
    _iscancelled(ctx.cancel) && return nothing
    _park!(_Waiter(ctx.rt), ctx.cancel, true)
    return nothing
end

"""
A pump: open `src` in this fiber, put every chunk on `q` as `_Msg(tag, …)`, then `:done` or the
failure. With `lease`, after `:done` it parks until it is cancelled (the operator's close) and only
then closes its input. `onend()` runs last (mergemap releases its slot there).
"""
function _pump(ctx::_Ctx, src, q::Queue{_Msg}, tag::Int, lease::Bool, onend)
    p = _sopen(src, ctx)
    try
        ScopedValues.with(_CTX => ctx) do
            while true
                r = _spull!(p, ctx)
                if r === nothing
                    ok, _ = _put!(q, _Msg(tag, _K_DONE, nothing), ctx)
                    ok && lease && _parkuntilcancel(ctx)
                    return nothing
                elseif r isa Cause
                    isinterrupted(r) || _put!(q, _Msg(tag, _K_FAIL, r), ctx)
                    return nothing
                end
                ok, _ = _put!(q, _Msg(tag, _K_CHUNK, r), ctx)
                ok || return nothing
            end
        end
    finally
        c = _sclose!(p, ctx)
        if c !== nothing && !isinterrupted(c)
            _tryput!(q, _Msg(tag, _K_FAIL, c))
        end
        onend === nothing || onend()
    end
    return nothing
end

_forkpump(ctx::_Ctx, src, q, tag, lease, onend = nothing) =
    _forkin(ctx, _fiberbody(c -> _pump(c, src, q, tag, lease, onend)), false)

# Take one message; a cancelled wait is the consumer's interruption.
function _takemsg!(q::Queue{_Msg}, ctx::_Ctx, deadline::Float64 = Inf)
    ok, m = _take!(q, ctx, deadline)
    ok || return m::Cause
    return m
end

# ---- merge and prefetch -----------------------------------------------------------------------------

struct _MergeSrc
    srcs::Vector{Any}
    capacity::Int
end
mutable struct _MergeP <: _Puller
    q::Queue{_Msg}
    fibers::Vector{Any}
    n::Int
    done::Int
    closed::Bool
end
function _open(s::_MergeSrc, ctx::_Ctx)
    n = length(s.srcs)
    q = Queue{_Msg}(s.capacity)
    fibers = Any[_forkpump(ctx, s.srcs[i], q, i, true) for i in 1:n]
    return _MergeP(q, fibers, n, 0, false)
end
function _pull!(p::_MergeP, ctx::_Ctx)
    while true
        p.done >= p.n && return nothing
        m = _takemsg!(p.q, ctx)
        m isa Cause && return m
        if m.kind == _K_CHUNK
            return m.val
        elseif m.kind == _K_DONE
            p.done += 1
        else
            return m.val::Cause
        end
    end
    return
end
function _close!(p::_MergeP, ctx::_Ctx)
    p.closed && return nothing
    p.closed = true
    _stopall!(p.fibers, ctx)
    return nothing
end

"""
    merge(s1::Stream, s2::Stream, …) -> Stream

The elements of every input as they arrive: each input runs in its own fiber of the run's scope,
and chunks are emitted in arrival order (within one input, in order). Ends when every input has
ended; the first failure fails the merge and stops the others. Same-instant arrivals on virtual
time follow subscription order (inputs are subscribed left to right).
"""
function Base.merge(s::Stream, ss::Stream...)
    all = (s, ss...)
    return _stream(_jointype(all), _MergeSrc(Any[x.src for x in all], 4 * length(all)))
end

"""
    prefetch(s::Stream; capacity = 4) -> Stream

An asynchronous boundary (Rx's `observeOn`/`subscribeOn`): `s` runs in its own fiber, up to
`capacity` chunks ahead of the consumer, so producer and consumer overlap.
"""
function prefetch(s::Stream{T}; capacity::Integer = 4) where {T}
    capacity >= 1 || throw(ArgumentError("prefetch: capacity must be at least 1, got $capacity"))
    return _stream(T, _MergeSrc(Any[s.src], Int(capacity)))
end

# ---- mergemap and switchmap: a coordinator fiber pulls the outer stream ------------------------------

struct _MapSrc
    f::Any
    src::Any
    maxconcurrent::Int       # 0 for switchmap
end
mutable struct _MapP <: _Puller
    q::Queue{_Msg}
    coord::Any
    gen::Threads.Atomic{Int}
    switch::Bool
    outerdone::Bool
    expect::Int              # mergemap: inners started; switchmap: the last generation
    innerdone::Int           # mergemap: inner ends seen; switchmap: generation whose end was seen
    closed::Bool
end

function _open(s::_MapSrc, ctx::_Ctx)
    q = Queue{_Msg}(4)
    gen = Threads.Atomic{Int}(0)
    sw = s.maxconcurrent == 0
    coord = _forkin(ctx, _fiberbody(c -> _coordinate(c, s, q, gen)), false)
    return _MapP(q, coord, gen, sw, false, 0, 0, false)
end

# The coordinator: pull the outer stream; start an inner pump per element; at the outer's end,
# report how many inners it started, wait for them, and only then close the outer (the lease).
function _coordinate(ctx::_Ctx, s::_MapSrc, q::Queue{_Msg}, gen::Threads.Atomic{Int})
    sw = s.maxconcurrent == 0
    sem = sw ? nothing : Queue{Nothing}(s.maxconcurrent)
    p = _sopen(s.src, ctx)
    inners = Any[]
    cur = nothing
    n = 0
    try
        ScopedValues.with(_CTX => ctx) do
            while true
                r = _spull!(p, ctx)
                if r === nothing
                    break
                elseif r isa Cause
                    isinterrupted(r) || _put!(q, _Msg(0, _K_FAIL, r), ctx)
                    return nothing
                end
                for x in r
                    inner = try
                        _streamof(s.f(x), sw ? "switchmap's function" : "mergemap's function")
                    catch ex
                        ex isa InterruptException && rethrow()
                        _put!(q, _Msg(0, _K_FAIL, _classify(ex, catch_backtrace(), 0x00, ctx)), ctx)
                        return nothing
                    end
                    if sw
                        g = Threads.atomic_add!(gen, 1) + 1      # bump first (spec §5)
                        cur === nothing || interrupt!(cur)       # no wait: awaited at the exit
                        cur = _forkpump(ctx, inner, q, g, false)
                        push!(inners, cur)
                    else
                        ok, _ = _put!(sem, nothing, ctx)         # a slot (cancellable)
                        ok || return nothing
                        n += 1
                        push!(inners, _forkpump(ctx, inner, q, 0, false, () -> _trytake!(sem)))
                    end
                    length(inners) > 64 && filter!(f -> !_isdone(f), inners)
                end
            end
            ok, _ = _put!(q, _Msg(0, _K_OUTERDONE, sw ? gen[] : n), ctx)
            ok || return nothing
            for f in inners                                      # the outer's lease
                _awaitfiber(f, ctx.cancel, _interruptible(ctx), ctx.rt) || return nothing
            end
        end
    catch ex
        ex isa InterruptException && rethrow()
        _tryput!(q, _Msg(0, _K_FAIL, Die(ex, catch_backtrace())))
    finally
        _stopall!(inners, ctx)
        c = _sclose!(p, ctx)
        c === nothing || isinterrupted(c) || _tryput!(q, _Msg(0, _K_FAIL, c))
    end
    return nothing
end

function _pull!(p::_MapP, ctx::_Ctx)
    while true
        if p.outerdone
            p.switch && (p.expect == 0 || p.innerdone == p.expect) && return nothing
            !p.switch && p.innerdone >= p.expect && return nothing
        end
        m = _takemsg!(p.q, ctx)
        m isa Cause && return m
        if m.kind == _K_OUTERDONE
            p.outerdone = true
            p.expect = m.val::Int
            continue
        end
        if p.switch && m.tag != 0 && m.tag != p.gen[]
            continue                                             # an earlier generation
        end
        if m.kind == _K_CHUNK
            return m.val
        elseif m.kind == _K_DONE
            if p.switch
                p.innerdone = m.tag
            else
                p.innerdone += 1
            end
        else
            return m.val::Cause
        end
    end
    return
end
function _close!(p::_MapP, ctx::_Ctx)
    p.closed && return nothing
    p.closed = true
    _stopall!((p.coord,), ctx)
    return nothing
end

"""
    mergemap(f, s::Stream; maxconcurrent = 16) -> Stream

For each element `x` of `s`, run the stream `f(x)` concurrently with the others (at most
`maxconcurrent` at once; the next waits for a slot) and emit their elements as they arrive (Rx
`mergeMap`). Ends when `s` and every inner stream have ended; the first failure fails it and
stops the rest. The outer stream is closed only after the inners it started have ended, so a
resource the outer emits stays open while inners use it. A resource acquired *inside* an inner
stream is released when that inner ends.
"""
function mergemap(f, s::Stream{T}; maxconcurrent::Integer = 16) where {T}
    maxconcurrent >= 1 || throw(ArgumentError("mergemap: maxconcurrent must be at least 1, got $maxconcurrent"))
    R = _ret(f, T)
    return _stream(_innertype(R), _MapSrc(f, s.src, Int(maxconcurrent)))
end

"""
    switchmap(f, s::Stream) -> Stream

For each element `x` of `s`, switch to the stream `f(x)`: the previous inner stream is
interrupted (without waiting for it) and its later chunks, end or failure are dropped, by
generation tag (Rx `switchMap`). Ends when `s` and the latest inner have ended.
"""
function switchmap(f, s::Stream{T}) where {T}
    R = _ret(f, T)
    return _stream(_innertype(R), _MapSrc(f, s.src, 0))
end
