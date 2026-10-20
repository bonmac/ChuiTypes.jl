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

# Wait (masked) until `ctx` is cancelled (a marble source with no terminal).
function _parkuntilcancel(ctx::_Ctx)
    _iscancelled(ctx.cancel) && return nothing
    _park!(_Waiter(ctx.rt), ctx.cancel, true)
    return nothing
end

# A pump's handle for its operator (review B2): the release waiter that ends a leased pump's park
# **without** cancelling it (so its input's releases see the run's real exit), and the cause its
# input's close failed with, read by the operator's `_close!` after the pump has ended.
mutable struct _PumpCtl
    lease::Bool
    release::_Waiter
    closecause::Union{Nothing, Cause}
    received::Bool                   # the consumer has taken this pump's `:done` (it is parked)
end
_PumpCtl(lease::Bool, rt) = _PumpCtl(lease, _Waiter(rt), nothing, false)

"""
A pump: open `src` in this fiber and put every chunk on `q` as `_Msg(tag, …)`.

- **Leased** (merge, prefetch, time operators): at the input's end it sends `:done` and parks
  until the operator **releases** it (`_fire!(ctl.release)`, a normal close: the input closes
  uncancelled) or cancels it (an interrupted or early-stopped run). Its close cause is kept in
  `ctl.closecause` for the operator's `_close!`.
- **Not leased** (mergemap/switchmap inners): at the input's end it closes the input **first**, then
  sends `:done`, or the close failure instead (a blocking `_put!`, so the consumer cannot end
  before it sees it; review S3).

`onend()` runs last (mergemap releases its slot there).
"""
function _pump(ctx::_Ctx, src, q::Queue{_Msg}, tag::Int, ctl::_PumpCtl, onend)
    p = _sopen(src, ctx)
    closed = false
    try
        ScopedValues.with(_CTX => ctx) do
            while true
                r = _spull!(p, ctx)
                if r === nothing
                    if ctl.lease
                        ok, _ = _put!(q, _Msg(tag, _K_DONE, nothing), ctx)
                        ok && _park!(ctl.release, ctx.cancel, true)
                    else
                        c = _sclose!(p, ctx)
                        closed = true
                        ctl.closecause = c
                        _put!(q, c === nothing ? _Msg(tag, _K_DONE, nothing) : _Msg(tag, _K_FAIL, c), ctx)
                    end
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
        if !closed
            c = _sclose!(p, ctx)
            c === nothing || (ctl.closecause = c)
        end
        onend === nothing || onend()
    end
    return nothing
end

function _forkpump(ctx::_Ctx, src, q, tag, lease::Bool, onend = nothing)
    ctl = _PumpCtl(lease, ctx.rt)
    f = _forkin(ctx, _fiberbody(c -> _pump(c, src, q, tag, ctl, onend)), false)
    return f, ctl
end

# Close leased pumps (review B2): when the run is not cancelled, release the pumps whose `:done`
# the consumer has taken (they are parked on the release, so their inputs close uncancelled);
# interrupt the rest (still producing, or blocked on a put nobody will take). Await all, masked;
# then the close causes, the first one with the others in its suppressed list.
function _closepumps!(fibers, ctls, ctx::_Ctx)
    normal = !_iscancelled(ctx.cancel)
    for (f, c) in zip(fibers, ctls)
        normal && c.received ? _fire!(c.release) : interrupt!(f)
    end
    for f in fibers
        _awaitfiber(f, ctx.cancel, false, ctx.rt)
    end
    return _firstcause(ctls)
end
function _firstcause(ctls)
    cs = Cause[]
    for ctl in ctls
        c = ctl.closecause                 # one read: a field re-read does not narrow
        c === nothing || isinterrupted(c) || push!(cs, c)
    end
    isempty(cs) && return nothing
    return length(cs) == 1 ? cs[1] : _suppress(cs[1], cs[2:end]...)
end

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
    ctls::Vector{_PumpCtl}
    n::Int
    done::Int
    closed::Bool
end
function _open(s::_MergeSrc, ctx::_Ctx)
    n = length(s.srcs)
    q = Queue{_Msg}(s.capacity)
    pumps = [_forkpump(ctx, s.srcs[i], q, i, true) for i in 1:n]
    return _MergeP(q, Any[first(x) for x in pumps], _PumpCtl[last(x) for x in pumps], n, 0, false)
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
            p.ctls[m.tag].received = true
        else
            return m.val::Cause
        end
    end
    return
end
function _close!(p::_MergeP, ctx::_Ctx)
    p.closed && return nothing
    p.closed = true
    return _closepumps!(p.fibers, p.ctls, ctx)
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
    ended::Bool              # the stream ended normally (the coordinator is finishing on its own)
    cctl::_PumpCtl           # the coordinator's outer close cause
    closed::Bool
end

function _open(s::_MapSrc, ctx::_Ctx)
    q = Queue{_Msg}(4)
    gen = Threads.Atomic{Int}(0)
    sw = s.maxconcurrent == 0
    cctl = _PumpCtl(false, ctx.rt)
    coord = _forkin(ctx, _fiberbody(c -> _coordinate(c, s, q, gen, cctl)), false)
    return _MapP(q, coord, gen, sw, false, 0, 0, false, cctl, false)
end

# The coordinator: pull the outer stream; start an inner pump per element; at the outer's end,
# report how many inners it started, wait for them, and only then close the outer (the lease).
# The outer's close cause goes to `cctl` (review B2), read by the consumer's `_close!`.
function _coordinate(ctx::_Ctx, s::_MapSrc, q::Queue{_Msg}, gen::Threads.Atomic{Int}, cctl::_PumpCtl)
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
                        cur = first(_forkpump(ctx, inner, q, g, false))
                        push!(inners, cur)
                    else
                        ok, _ = _put!(sem, nothing, ctx)         # a slot (cancellable)
                        ok || return nothing
                        n += 1
                        push!(inners, first(_forkpump(ctx, inner, q, 0, false, () -> _trytake!(sem))))
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
        d = Die(ex, catch_backtrace())
        _tryput!(q, _Msg(0, _K_FAIL, d)) || (cctl.closecause = d)    # never lose a defect
    finally
        _stopall!(inners, ctx)
        c = _sclose!(p, ctx)
        if c !== nothing
            cctl.closecause = cctl.closecause === nothing ? c : _suppress(something(cctl.closecause), c)
        end
    end
    return nothing
end

function _pull!(p::_MapP, ctx::_Ctx)
    while true
        if p.outerdone && (p.switch ? (p.expect == 0 || p.innerdone == p.expect) : p.innerdone >= p.expect)
            p.ended = true
            return nothing
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
    if p.ended && !_iscancelled(ctx.cancel)
        # a normal end: every inner has ended, so the coordinator closes the outer on its own,
        # uncancelled (its releases see the real exit; review B2); wait for it, masked
        _awaitfiber(p.coord, ctx.cancel, false, ctx.rt)
    else
        _stopall!((p.coord,), ctx)
    end
    c = p.cctl.closecause
    return c === nothing || isinterrupted(c) ? nothing : c
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
