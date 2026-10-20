# These{A,B}: an `A`, a `B`, or both (ADR-0001 §2: tag plus two slots).

const _THIS = 0x00
const _THAT = 0x01
const _BOTH = 0x02

"""
    These{A,B}

A value that is `this(a, B)` (only an `A`), `that(A, b)` (only a `B`) or `both(a, b)`. A
concrete struct with a `UInt8` tag and one `Union{Nothing,⋅}` slot per side (ADR-0001).

`map`, iteration and `traverse` act on the `B` side. The Applicative and Monad instances combine
`A` values with the monoid instance `default_monoid(A)`, so they exist only for an `A` that
declares one (ADR-0001 §10: "when `A` is a Semigroup").

The constructors and predicates `this`, `that`, `both`, `isthis`, `isthat`, `isboth`, `here` and
`there` are public but not exported: write `ChuiTypes.both(1, "b")`.
"""
struct These{A, B}
    tag::UInt8
    a::Union{Nothing, A}
    b::Union{Nothing, B}
    These{A, B}(::_New, tag::UInt8, a, b) where {A, B} = new{A, B}(tag, a, b)
end

"""
    this(a, B)

The `These{typeof(a),B}` holding only `a`. Public, not exported.
"""
this(a, ::Type{B}) where {B} = These{typeof(a), B}(_NEW, _THIS, a, nothing)

"""
    that(A, b)

The `These{A,typeof(b)}` holding only `b`. Public, not exported.
"""
that(::Type{A}, b) where {A} = These{A, typeof(b)}(_NEW, _THAT, nothing, b)

"""
    both(a, b)

The `These{typeof(a),typeof(b)}` holding `a` and `b`. Public, not exported.
"""
both(a, b) = These{typeof(a), typeof(b)}(_NEW, _BOTH, a, b)

# Internal constructors that keep a declared (possibly abstract) parameter.
_this(::Type{A}, ::Type{B}, a) where {A, B} = These{A, B}(_NEW, _THIS, a, nothing)
_that(::Type{A}, ::Type{B}, b) where {A, B} = These{A, B}(_NEW, _THAT, nothing, b)
_both(::Type{A}, ::Type{B}, a, b) where {A, B} = These{A, B}(_NEW, _BOTH, a, b)
_geta(t::These{A}) where {A} = t.a::A
_getb(t::These{A, B}) where {A, B} = t.b::B

"`isthis(t)`: whether `t` holds only an `A`. Public, not exported."
isthis(t::These) = t.tag == _THIS
"`isthat(t)`: whether `t` holds only a `B`. Public, not exported."
isthat(t::These) = t.tag == _THAT
"`isboth(t)`: whether `t` holds both. Public, not exported."
isboth(t::These) = t.tag == _BOTH

"""
    here(t::These{A,B}) -> Option{A}

The `A` side of `t`, if any. Public, not exported.
"""
here(t::These{A}) where {A} = isthat(t) ? none(A) : _some(A, _geta(t))

"""
    there(t::These{A,B}) -> Option{B}

The `B` side of `t`, if any. Public, not exported.
"""
there(t::These{A, B}) where {A, B} = isthis(t) ? none(B) : _some(B, _getb(t))

Base.iterate(t::These, done::Bool = false) = (!isthis(t) && !done) ? (_getb(t), true) : nothing
Base.length(t::These) = Int(!isthis(t))
Base.eltype(::Type{These{A, B}}) where {A, B} = B
Base.Iterators.reverse(t::These) = t

# Functor over the B side
function Base.map(f, t::These{A, B}) where {A, B}
    isthis(t) && return _this(A, Base.promote_op(f, B), _geta(t))
    y = f(_getb(t))
    return isthat(t) ? _that(A, typeof(y), y) : _both(A, typeof(y), _geta(t), y)
end
Upstream.fmap(f, t::These) = map(f, t)

# Bifunctor
function Upstream.bimap(f, g, t::These{A, B}) where {A, B}
    isthis(t) && return this(f(_geta(t)), Base.promote_op(g, B))
    isthat(t) && return that(Base.promote_op(f, A), g(_getb(t)))
    return both(f(_geta(t)), g(_getb(t)))
end

# Applicative and Monad: A values are combined with `default_monoid(A)`.
_combine_a(::Type{A}, x, y) where {A} = Upstream.combine(Upstream.default_monoid(A), x, y)

Upstream.pure(::TheseTag{A}, x) where {A} = that(A, x)

function Upstream.ap(ff::These{A, F}, fx::These{A, T}) where {A, F, T}
    S = Base.promote_op(_call, F, T)
    isthis(ff) && return _this(A, S, _geta(ff))
    isthat(ff) && return map(_getb(ff), fx)
    a = _geta(ff)
    isthis(fx) && return _this(A, S, _combine_a(A, a, _geta(fx)))
    y = _getb(ff)(_getb(fx))
    isthat(fx) && return _both(A, typeof(y), a, y)
    return _both(A, typeof(y), _combine_a(A, a, _geta(fx)), y)
end

function Upstream.chain(f, t::These{A, B}) where {A, B}
    isthis(t) && return _this(A, _param(These, Base.promote_op(f, B), 2), _geta(t))
    r = f(_getb(t))::These{A}
    isthat(t) && return r
    return _chain_both(A, _geta(t), r)
end
function _chain_both(::Type{A}, a, r::These{A2, B2}) where {A, A2, B2}
    isthis(r) && return _this(A, B2, _combine_a(A, a, _geta(r)))
    isthat(r) && return _both(A, B2, a, _getb(r))
    return _both(A, B2, _combine_a(A, a, _geta(r)), _getb(r))
end

# Traversable over the B side
function Upstream.traverse(tag, f, t::These{A, B}) where {A, B}
    isthis(t) && return Upstream.pure(tag, _this(A, _valparam(Base.promote_op(f, B)), _geta(t)))
    isthat(t) && return Upstream.fmap(y -> _that(A, typeof(y), y), f(_getb(t)))
    a = _geta(t)
    return Upstream.fmap(y -> _both(A, typeof(y), a, y), f(_getb(t)))
end

Upstream.constructorclass(::Type{These{A, B}}) where {A, B} = TheseTag{A}()
_mappedindex(::Type{<:These}) = 2

function Base.:(==)(x::These, y::These)
    x.tag == y.tag || return false
    isthis(x) && return _geta(x) == _geta(y)
    isthat(x) && return _getb(x) == _getb(y)
    return (_geta(x) == _geta(y)) & (_getb(x) == _getb(y))
end
function Base.isequal(x::These, y::These)
    x.tag == y.tag || return false
    isthis(x) && return isequal(_geta(x), _geta(y))
    isthat(x) && return isequal(_getb(x), _getb(y))
    return isequal(_geta(x), _geta(y)) && isequal(_getb(x), _getb(y))
end
const _H_THESE = (0x1d4b7e2a9c6f3085 % UInt, 0x7a2e9d4c1b8f6053 % UInt, 0xc8f1a63e5d2b7094 % UInt)
function Base.hash(t::These, h::UInt)
    h = h ⊻ _H_THESE[t.tag + 1]
    isthat(t) || (h = hash(_geta(t), h))
    isthis(t) || (h = hash(_getb(t), h))
    return h
end

function Base.show(io::IO, t::These{A, B}) where {A, B}
    if isthis(t)
        print(io, "ChuiTypes.this(")
        show(io, _geta(t))
        print(io, ", ")
        show(io, B)
    elseif isthat(t)
        print(io, "ChuiTypes.that(")
        show(io, A)
        print(io, ", ")
        show(io, _getb(t))
    else
        print(io, "ChuiTypes.both(")
        show(io, _geta(t))
        print(io, ", ")
        show(io, _getb(t))
    end
    return print(io, ")")
end
