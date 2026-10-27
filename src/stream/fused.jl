# Fused element operators (ADR-0003 §2, ADR-0004; phase-4 spec §3): every element operator adds
# a transducer to one `_Fused` node, run by one specialised loop per chunk.

const U = Upstream

struct _Fused
    src::Any
    xf::U.Transducer
    T::Type                 # the advisory output type: the sink's fast path
end

# The node `s` with `xf` appended to its pipeline (one node over the source, never a chain).
_fuse(::Type{T}, s::Stream, xf::U.Transducer) where {T} =
    s.src isa _Fused ? _stream(T, _Fused(s.src.src, U.opcompose(s.src.xf, xf), T)) : _stream(T, _Fused(s.src, xf, T))

# `acc` is the pipeline's accumulator: a `_SinkAcc` (the sink and its fill count), wrapped in a
# `U._State` per stateful layer.
mutable struct _FusedP{RF, A} <: _Puller
    up::Any
    rf::RF
    acc::A
    done::Bool
    pending::Union{Nothing, Cause}
    # The last `ctx` pulled with, already boxed: handing it to the dynamic `_spull!(up, …)` call
    # then allocates nothing (a fresh `_Ctx` box per chunk otherwise).
    ctxbox::Any
end

function _open(f::_Fused, ctx::_Ctx)
    rf = U.asrf(f.xf, _sinkpush)
    return _openfused(rf, _sopen(f.src, ctx), f.T)
end
# The sink's fast path is the advisory output type; widening covers anything else.
function _openfused(rf, up, ::Type{T}) where {T}
    acc = U.start(rf, _SinkAcc(_Sink{T}()))
    return _FusedP{typeof(rf), typeof(acc)}(up, rf, acc, false, nothing, nothing)
end

# The sink accumulator inside a pipeline accumulator, and the accumulator with an emptied sink.
_bottom(a::_SinkAcc) = a
_bottom(a::U._State) = _bottom(a.acc)
_emptied(a::_SinkAcc) = _SinkAcc(a.s)
_emptied(a::U._State{S}) where {S} = U._State{S}(a.state, _emptied(a.acc))

# The in-chunk loop (the function barrier: specialised on `rf`, `acc` and the chunk type).
function _runchunk(rf::RF, acc::A, chunk) where {RF, A}
    for x in chunk
        a = U.next(rf, acc, x)
        a isa U.Reduced && return a
        acc = a
    end
    return acc
end

# One chunk through the pipeline: the one dynamic call per chunk, on the puller (already on the
# heap) and the chunk (already boxed), so `rf` and `acc` are never boxed. Stores the new
# accumulator and returns `nothing`; on `Reduced`, completes and returns the final `_SinkAcc`.
function _fusedchunk!(p::_FusedP, chunk)
    a = _runchunk(p.rf, p.acc, chunk)
    a isa U.Reduced && return _bottom(U.complete(p.rf, a.value))
    p.acc = a
    return nothing
end

function _pull!(p::_FusedP, ctx::_Ctx)
    if p.done
        c = p.pending
        p.pending = nothing
        return c
    end
    cb = p.ctxbox
    if !(cb isa _Ctx && cb === ctx)
        p.ctxbox = ctx
    end
    while true
        r = _spull!(p.up, p.ctxbox)     # checks the cancel state: an empty output re-pulls (review B1)
        if r === nothing
            p.done = true
            last = _bottom(U.complete(p.rf, p.acc))
            _sinkempty(last) && return nothing
            return _emit!(last)
        elseif r isa Cause
            p.done = true
            return r
        end
        last = _fusedchunk!(p, r)
        if last !== nothing
            p.done = true
            # stop the upstream at once: its fibers end and its releases run now
            p.pending = _sclose!(p.up, ctx)
            p.up = _EndP()
            _sinkempty(last) && return _pull!(p, ctx)
            return _emit!(last)
        end
        b = _bottom(p.acc)
        if !_sinkempty(b)
            chunk = _emit!(b)
            p.acc = _emptied(p.acc)
            return chunk
        end
    end
    return
end
_close!(p::_FusedP, ctx::_Ctx) = _close!(p.up, ctx)

# ---- The operators ---------------------------------------------------------------------------------

"""
    map(f, s::Stream) -> Stream

The stream of `f(x)` for each element `x` of `s` (fused with neighbouring element operators).
"""
Base.map(f, s::Stream{T}) where {T} = _fuse(_ret(f, T), s, U.Map(f))

"""
    filter(p, s::Stream) -> Stream

The elements `x` of `s` with `p(x)` (fused).
"""
Base.filter(p, s::Stream{T}) where {T} = _fuse(T, s, U.Filter(p))

"""
    scan(op, init, s::Stream) -> Stream

Rx `scan`: the running accumulations `op(acc, x)`, starting from `init` (which is not emitted).
The accumulator is carried across chunks (fused), and widens from `typeof(init)` to the type of
`op(acc, x)` like `Base.accumulate`.
"""
function scan(op, init, s::Stream{T}) where {T}
    R1 = _ret(op, typeof(init), T)
    R = typejoin(R1, _ret(op, R1, T))
    S = Union{typeof(init), R}
    return _fuse(R, s, U.Scan{typeof(op), S}(op, init))
end

"""
    Iterators.take(s::Stream, n) -> Stream

The first `n` elements of `s`. When the `n`th arrives the upstream is closed at once (its fibers
stop and its releases run) and nothing more is pulled.
"""
function Base.Iterators.take(s::Stream{T}, n::Integer) where {T}
    n >= 0 || throw(ArgumentError("take: n must be non-negative, got $n"))
    n == 0 && return emptystream(T)
    return _fuse(T, s, U.Take(Int(n)))
end

"""
    Iterators.takewhile(p, s::Stream) -> Stream

The elements of `s` while `p(x)` holds; the first `x` with `!p(x)` ends the stream (and closes
the upstream at once).
"""
Base.Iterators.takewhile(p, s::Stream{T}) where {T} = _fuse(T, s, U.TakeWhile(p))

struct _Drop <: U.Transducer
    n::Int
end
U.start(rf::U.R{_Drop}, acc) = U._State(0, U.start(rf.inner, acc))
function U.next(rf::U.R{_Drop}, w::U._State, x)
    w.state < rf.xf.n && return U._State(w.state + 1, w.acc)
    return U._rewrap(w.state, U.next(rf.inner, w.acc, x))
end
U.complete(rf::U.R{_Drop}, w::U._State) = U.complete(rf.inner, w.acc)

"""
    Iterators.drop(s::Stream, n) -> Stream

`s` without its first `n` elements (fused; the count is carried across chunks).
"""
function Base.Iterators.drop(s::Stream{T}, n::Integer) where {T}
    n >= 0 || throw(ArgumentError("drop: n must be non-negative, got $n"))
    return _fuse(T, s, _Drop(Int(n)))
end

_tight(v) = map(identity, v)

"""
    buffer(s::Stream, n) -> Stream{Vector}

Count-based buffering: vectors of `n` consecutive elements; the last one may be shorter. The
group is carried across chunks (fused). For time-based groups use [`buffertime`](@ref).
"""
function buffer(s::Stream{T}, n::Integer) where {T}
    n >= 1 || throw(ArgumentError("buffer: n must be at least 1, got $n"))
    return _fuse(Vector{T}, s, U.opcompose(U.Partition{Any}(Int(n)), U.Map(_tight)))
end

"""
    window(s::Stream, n) -> Stream{Stream}

Like [`buffer`](@ref), with each group of `n` elements given as a finite `Stream`. Unlike Rx's
`window`, the group is buffered before its stream is emitted: a pull stream cannot hand out a
live inner stream without a task boundary per window.
"""
window(s::Stream{T}, n::Integer) where {T} = _fuse(Stream{T}, buffer(s, n), U.Map(fromiter))
