# Either{L,R}: a left (failure) or right (success) value (ADR-0001 §2: tag plus two slots).

const _LEFT = 0x00
const _RIGHT = 0x01

"""
    Either{L,R}

A value that is either `left(x, R)` (an `L`, conventionally a failure) or `right(L, x)` (an
`R`). A concrete struct with a `UInt8` tag and one `Union{Nothing,⋅}` slot per side
(ADR-0001), so `Either{String,Int}` chains do not allocate.

`map`, iteration and `get` act on the right side (right-biased).

# Examples
```jldoctest
julia> map(x -> x + 1, right(String, 1))
right(String, 2)

julia> map(x -> x + 1, left("oops", Int))
left("oops", Int64)
```
"""
struct Either{L, R}
    tag::UInt8
    l::Union{Nothing, L}
    r::Union{Nothing, R}
    Either{L, R}(::_New, tag::UInt8, l, r) where {L, R} = new{L, R}(tag, l, r)
end

"""
    left(x, R)

The `Either{typeof(x),R}` holding `x` on the left. The right type `R` is required (ADR-0001 §3).
"""
left(x, ::Type{R}) where {R} = Either{typeof(x), R}(_NEW, _LEFT, x, nothing)

"""
    right(L, x)

The `Either{L,typeof(x)}` holding `x` on the right. The left type `L` is required (ADR-0001 §3).
"""
right(::Type{L}, x) where {L} = Either{L, typeof(x)}(_NEW, _RIGHT, nothing, x)

# Internal constructors that keep a declared (possibly abstract) parameter.
_left(::Type{L}, ::Type{R}, x) where {L, R} = Either{L, R}(_NEW, _LEFT, x, nothing)
_right(::Type{L}, ::Type{R}, x) where {L, R} = Either{L, R}(_NEW, _RIGHT, nothing, x)
_getl(e::Either{L}) where {L} = e.l::L
_getr(e::Either{L, R}) where {L, R} = e.r::R

"""
    isleft(e::Either) -> Bool

Whether `e` holds a left value.
"""
isleft(e::Either) = e.tag == _LEFT

"""
    isright(e::Either) -> Bool

Whether `e` holds a right value.
"""
isright(e::Either) = e.tag == _RIGHT

"""
    fromleft(e::Either)

The left value of `e`; throws an `ArgumentError` if `e` is right.
"""
fromleft(e::Either) = isleft(e) ? _getl(e) : throw(ArgumentError("fromleft: $(repr(e)) is right"))

"""
    fromright(e::Either)

The right value of `e`; throws an `ArgumentError` if `e` is left.
"""
fromright(e::Either) = isright(e) ? _getr(e) : throw(ArgumentError("fromright: $(repr(e)) is left"))

Base.get(e::Either, default) = isright(e) ? _getr(e) : default

Base.iterate(e::Either, done::Bool = false) = (isright(e) && !done) ? (_getr(e), true) : nothing
Base.length(e::Either) = Int(isright(e))
Base.eltype(::Type{Either{L, R}}) where {L, R} = R
Base.Iterators.reverse(e::Either) = e

# Functor (right-biased). The left branch takes its new parameter from `promote_op` (ADR-0001 §4).
function Base.map(f, e::Either{L, R}) where {L, R}
    isright(e) && return right(L, f(_getr(e)))
    return _left(L, Base.promote_op(f, R), _getl(e))
end
Upstream.fmap(f, e::Either) = map(f, e)

# Applicative (left-biased on failures: the function's left wins)
Upstream.pure(::EitherTag{L}, x) where {L} = right(L, x)
function Upstream.ap(ff::Either{L, F}, fx::Either{L, T}) where {L, F, T}
    (isright(ff) && isright(fx)) && return right(L, _getr(ff)(_getr(fx)))
    S = Base.promote_op(_call, F, T)
    return _left(L, S, isleft(ff) ? _getl(ff) : _getl(fx))
end

# Monad
function Upstream.chain(f, e::Either{L, R}) where {L, R}
    isright(e) && return f(_getr(e))::Either
    return _left(L, _param(Either, Base.promote_op(f, R), 2), _getl(e))
end

# Bifunctor
function Upstream.bimap(f, g, e::Either{L, R}) where {L, R}
    isleft(e) && return left(f(_getl(e)), Base.promote_op(g, R))
    return right(Base.promote_op(f, L), g(_getr(e)))
end

# Traversable
function Upstream.traverse(tag, f, e::Either{L, R}) where {L, R}
    isright(e) && return Upstream.fmap(y -> right(L, y), f(_getr(e)))
    return Upstream.pure(tag, _left(L, _valparam(Base.promote_op(f, R)), _getl(e)))
end

Upstream.constructorclass(::Type{Either{L, R}}) where {L, R} = EitherTag{L}()
_mappedindex(::Type{<:Either}) = 2

function Base.:(==)(a::Either, b::Either)
    a.tag == b.tag || return false
    return isleft(a) ? _getl(a) == _getl(b) : _getr(a) == _getr(b)
end
function Base.isequal(a::Either, b::Either)
    a.tag == b.tag || return false
    return isleft(a) ? isequal(_getl(a), _getl(b)) : isequal(_getr(a), _getr(b))
end
const _H_LEFT = 0x4b7d2a1e6c9f3058 % UInt
const _H_RIGHT = 0x91c3e5b7a2d4f608 % UInt
Base.hash(e::Either, h::UInt) = isleft(e) ? hash(_getl(e), h ⊻ _H_LEFT) : hash(_getr(e), h ⊻ _H_RIGHT)

function Base.show(io::IO, e::Either{L, R}) where {L, R}
    if isleft(e)
        print(io, "left(")
        show(io, _getl(e))
        print(io, ", ")
        show(io, R)
    else
        print(io, "right(")
        show(io, L)
        print(io, ", ")
        show(io, _getr(e))
    end
    return print(io, ")")
end
