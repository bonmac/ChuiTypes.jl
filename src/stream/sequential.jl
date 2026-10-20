# Sequential combinators, without fibers (phase-4 spec §5, §6): concat, concatmap, catchfail, retry.

_streamof(x, what) = x isa Stream ? x.src : throw(ArgumentError("$what must return a Stream, got a $(typeof(x))"))

# ---- concat -----------------------------------------------------------------------------------------

struct _ConcatSrc
    srcs::Vector{Any}
end
mutable struct _ConcatP <: _Puller
    srcs::Vector{Any}
    i::Int
    cur::Any
end
_open(s::_ConcatSrc, ::_Ctx) = _ConcatP(s.srcs, 0, nothing)
function _pull!(p::_ConcatP, ctx::_Ctx)
    while true
        if p.cur === nothing
            p.i += 1
            p.i > length(p.srcs) && return nothing
            p.cur = _sopen(p.srcs[p.i], ctx)
        end
        r = _pull!(p.cur, ctx)
        r === nothing || return r
        c = _sclose!(p.cur, ctx)
        p.cur = nothing
        c === nothing || return c
    end
    return
end
function _close!(p::_ConcatP, ctx::_Ctx)
    p.cur === nothing && return nothing
    c = _close!(p.cur, ctx)
    p.cur = nothing
    return c
end

"""
    concat(s1::Stream, s2::Stream, …) -> Stream

The elements of `s1`, then of `s2`, and so on: each stream is opened when the previous one has
ended and been closed. A failure ends the concatenation.
"""
concat(ss::Stream...) = _stream(_jointype(ss), _ConcatSrc(Any[s.src for s in ss]))
_jointype(ss) = isempty(ss) ? Union{} : mapreduce(eltype, typejoin, ss)

# ---- concatmap --------------------------------------------------------------------------------------

struct _ConcatMapSrc
    f::Any
    src::Any
end
mutable struct _ConcatMapP <: _Puller
    f::Any
    outer::Any
    chunk::Any
    i::Int
    inner::Any
    outerdone::Bool
end
_open(s::_ConcatMapSrc, ctx::_Ctx) = _ConcatMapP(s.f, _sopen(s.src, ctx), nothing, 0, nothing, false)
function _pull!(p::_ConcatMapP, ctx::_Ctx)
    while true
        if p.inner !== nothing
            r = _pull!(p.inner, ctx)
            r === nothing || return r
            c = _sclose!(p.inner, ctx)
            p.inner = nothing
            c === nothing || return c
        end
        if p.chunk === nothing || p.i >= length(p.chunk)
            p.outerdone && return nothing
            r = _pull!(p.outer, ctx)
            if r === nothing
                p.outerdone = true
                return nothing
            end
            r isa Cause && return r
            p.chunk = r
            p.i = 0
        end
        p.i += 1
        x = p.chunk[p.i]
        p.inner = _sopen(_streamof(p.f(x), "concatmap's function"), ctx)
        _interruptible(ctx) && _iscancelled(ctx.cancel) && return Interrupted()
    end
    return
end
function _close!(p::_ConcatMapP, ctx::_Ctx)
    c1 = p.inner === nothing ? nothing : _close!(p.inner, ctx)
    p.inner = nothing
    c2 = _close!(p.outer, ctx)
    c1 === nothing && return c2
    return c2 === nothing ? c1 : _suppress(c1, c2)
end

"""
    concatmap(f, s::Stream) -> Stream

For each element `x` of `s`, in order, the elements of the stream `f(x)`, run to its end before
the next one opens (the stream monad's `chain`). No fibers.
"""
function concatmap(f, s::Stream{T}) where {T}
    R = _ret(f, T)
    return _stream(_innertype(R), _ConcatMapSrc(f, s.src))
end
# The element type of the streams a function returns (advisory): `Union{}` when it never returns.
_innertype(R) = R === Union{} ? Union{} : R <: Stream ? (isconcretetype(R) ? eltype(R) : Any) : Any

# ---- catchfail --------------------------------------------------------------------------------------

struct _CatchSrc
    h::Any
    src::Any
end
mutable struct _CatchP <: _Puller
    h::Any
    cur::Any
    caught::Bool
end
_open(s::_CatchSrc, ctx::_Ctx) = _CatchP(s.h, _sopen(s.src, ctx), false)
function _pull!(p::_CatchP, ctx::_Ctx)
    r = _pull!(p.cur, ctx)
    if r isa Cause && isfail(r) && !p.caught
        p.caught = true
        c = _sclose!(p.cur, ctx)
        p.cur = _EndP()
        c === nothing || return c
        p.cur = _sopen(_streamof(p.h(r.e), "catchfail's handler"), ctx)
        return _pull!(p, ctx)
    end
    return r
end
_close!(p::_CatchP, ctx::_Ctx) = _close!(p.cur, ctx)

"""
    catchfail(h, s::Stream) -> Stream

`s`, and if it fails with `Fail(e)`, the elements of the stream `h(e)` after the ones `s`
already emitted. Defects (`Die`) and interruption are not caught.
"""
catchfail(h, s::Stream{T}) where {T} = _stream(Any, _CatchSrc(h, s.src))

# ---- retry ------------------------------------------------------------------------------------------

struct _RetrySrc
    src::Any
    sched::Schedule
end
mutable struct _RetryP <: _Puller
    s::_RetrySrc
    cur::Any
    n::Int
end
_open(s::_RetrySrc, ctx::_Ctx) = _RetryP(s, _sopen(s.src, ctx), 0)
function _pull!(p::_RetryP, ctx::_Ctx)
    while true
        r = _pull!(p.cur, ctx)
        (r isa Cause && isfail(r)) || return r
        c = _sclose!(p.cur, ctx)
        p.cur = _EndP()
        c === nothing || return c
        p.n += 1
        d = p.s.sched.next(p.n)
        d === nothing && return r
        ok, cz = _sleep(_clockof(ctx), Float64(d), ctx)
        ok || return cz
        p.cur = _sopen(p.s.src, ctx)
    end
    return
end
_close!(p::_RetryP, ctx::_Ctx) = _close!(p.cur, ctx)

"""
    retry(s::Stream, sched::Schedule) -> Stream

`s`, run again from the start after each `Fail(e)` while the schedule allows, waiting its delay
on the environment's clock first; elements already emitted stay emitted (Rx `retry`). Defects
(`Die`) and interruption are not retried; after the last allowed retry the failure stands.
"""
Base.retry(s::Stream{T}, sched::Schedule) where {T} = _stream(T, _RetrySrc(s.src, sched))
