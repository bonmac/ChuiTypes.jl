# `fromiter`'s sources (included from core.jl; phase-5 spec D2, D3): an indexed source for a
# `Vector`, a range or a linear view of a `Vector`, and the generic iteration source.

# ---- The generic source: iterate, with the state behind a function barrier ------------------------
# `S` is the iteration state type that inference gives for both `iterate(itr)` and
# `iterate(itr, ::S)`, when it is concrete; otherwise `Any` (never the runtime type of the first
# state: an iterator whose state type changes would fail the field assignment).

struct _IterSrc{I}
    itr::I
    chunksize::Int
end
mutable struct _IterP{I, S} <: _Puller
    itr::I
    chunksize::Int
    started::Bool
    state::Union{Nothing, S}
    done::Bool
end

# The state type of a `Union{Nothing, Tuple{X, S}}` (what `iterate` returns), else `Any`.
function _statepart(@nospecialize Y)
    if Y isa Union
        Y = Y.a === Nothing ? Y.b : Y.b === Nothing ? Y.a : Any
    end
    return Y isa DataType && Y <: Tuple && length(Y.parameters) == 2 ? Y.parameters[2] : Any
end
function _statetype(::Type{I}) where {I}
    S1 = _statepart(Base.promote_op(iterate, I))
    isconcretetype(S1) || return Any
    S2 = _statepart(Base.promote_op(iterate, I, S1))
    return S2 === S1 ? S1 : Any
end

function _open(s::_IterSrc{I}, ::_Ctx) where {I}
    return _IterP{I, _statetype(I)}(s.itr, s.chunksize, false, nothing, false)
end
function _pull!(p::_IterP{I, S}, ::_Ctx) where {I, S}
    p.done && return nothing
    y = p.started ? iterate(p.itr, p.state::S) : iterate(p.itr)
    p.started = true
    y === nothing && (p.done = true; return nothing)
    chunk, st, more = _fillchunk(p.itr, y, p.chunksize, eltype(p.itr))
    p.state = st
    more || (p.done = true)
    return chunk
end
_close!(::_IterP, ::_Ctx) = nothing

# The in-chunk loop, specialised on the iterator and its state (the function barrier).
function _fillchunk(itr, y, n::Int, ::Type{T}) where {T}
    a = _SinkAcc(_Sink{T}(n))
    k = 0
    while true
        x, st = y
        a = _sinkpush(a, x)
        k += 1
        if k == n
            return _take!(a), st, true
        end
        y = iterate(itr, st)
        y === nothing && return _take!(a), st, false
    end
    return
end

# ---- The indexed source ---------------------------------------------------------------------------
# A typed cursor from `firstindex` (offset axes); each pull re-reads `lastindex` (cold: the vector
# as it is at that pull) and copies the next `min(chunksize, remaining)` elements into a fresh
# `Vector{eltype}`: `copyto!` for bits types, else through `getindex`, so an undefined slot throws
# `UndefRefError` as iteration does. Other `AbstractVector`s keep the generic path (their
# `getindex` may not return `eltype` values, or their axes may be fixed at iteration start).

struct _IdxSrc{A}
    a::A
    chunksize::Int
end
mutable struct _IdxP{A} <: _Puller
    a::A
    chunksize::Int
    i::Int
    done::Bool
end
_open(s::_IdxSrc, ::_Ctx) = _IdxP(s.a, s.chunksize, Int(firstindex(s.a)), false)
function _pull!(p::_IdxP, ::_Ctx)
    p.done && return nothing
    a = p.a
    i = p.i
    n = min(p.chunksize, Int(lastindex(a)) - i + 1)
    # A short chunk ends the stream, as iteration does (it saw the end inside that chunk).
    n < p.chunksize && (p.done = true)
    n <= 0 && return nothing
    v = _copychunk(a, i, n)
    p.i = i + n
    return v
end
_close!(::_IdxP, ::_Ctx) = nothing

function _copychunk(a::AbstractVector{T}, i::Int, n::Int) where {T}
    v = Vector{T}(undef, n)
    if isbitstype(T) && !(a isa AbstractRange)
        copyto!(v, 1, a, i, n)
    elseif a isa Vector              # `i:i+n-1` is within the `lastindex` read by this pull
        @inbounds for k in 1:n
            v[k] = a[i + k - 1]
        end
    else
        # A view's parent may have shrunk: keep the checked read. Ranges keep it too: an unchecked
        # (vectorised) range copy is 2.6x faster here but made `merge` over range sources about
        # 3x slower per element (median; faster pumps, cause not established; measured
        # 2026-10-26, evidence p5-perf-merge). Revisit with merge's scheduling.
        for k in 1:n
            x = a[i + k - 1]
            @inbounds v[k] = x
        end
    end
    return v
end

_source(itr, n::Int) = _IterSrc(itr, n)
_source(a::Union{Vector, AbstractRange}, n::Int) = _IdxSrc(a, n)
_source(a::SubArray{<:Any, 1, <:Vector}, n::Int) = IndexStyle(a) === IndexLinear() ? _IdxSrc(a, n) : _IterSrc(a, n)

"""
    fromiter(itr; chunksize = 1024) -> Stream{eltype(itr)}

The cold stream of `itr`'s elements, in chunks of `chunksize`. Every run iterates `itr` again
from the start; an unbounded iterator gives an unbounded stream (bound it with `take`). A
`Vector` is read as it is at each chunk (a vector that grows or shrinks during a run is seen so).
"""
function fromiter(itr; chunksize::Integer = _CHUNK)
    chunksize >= 1 || throw(ArgumentError("chunksize must be at least 1, got $chunksize"))
    return _stream(eltype(itr), _source(itr, Int(chunksize)))
end
