# Option{T}: an optional value (ADR-0001 §2: `has::Bool` plus one `Union{Nothing,T}` slot).

"""
    Option{T}

An optional value of type `T`: either `some(x)` or `none(T)`. A concrete struct with a `Bool`
tag and one `Union{Nothing,T}` slot (ADR-0001), so `Option{Int}` is stored inline and
`Option{Nothing}` still tells `some(nothing)` from `none(Nothing)`.

Base integration: `map`, `iterate` (zero or one element), `length`, `get(o, default)`,
`foldl`/`foldr`, `==`, `isequal`, `hash`, `show`.

# Examples
```jldoctest
julia> map(x -> x + 1, some(1))
some(2)

julia> get(none(Int), 0)
0
```
"""
struct Option{T}
    has::Bool
    v::Union{Nothing, T}
    Option{T}(::_New, has::Bool, v) where {T} = new{T}(has, v)
end

"""
    some(x)

The `Option{typeof(x)}` holding `x`. See also [`none`](@ref).
"""
some(x) = Option{typeof(x)}(_NEW, true, x)

"""
    none(T)

The empty `Option{T}`. The element type is required, so empty and full options have the same
concrete type (ADR-0001 §3).
"""
none(::Type{T}) where {T} = Option{T}(_NEW, false, nothing)

_some(::Type{T}, x) where {T} = Option{T}(_NEW, true, x)
_get(o::Option{T}) where {T} = o.v::T

"""
    issome(o::Option) -> Bool

Whether `o` holds a value.
"""
issome(o::Option) = o.has

"""
    isnone(o::Option) -> Bool

Whether `o` is empty.
"""
isnone(o::Option) = !o.has

Base.get(o::Option, default) = o.has ? _get(o) : default

Base.iterate(o::Option, done::Bool = false) = (o.has && !done) ? (_get(o), true) : nothing
Base.length(o::Option) = Int(o.has)
Base.eltype(::Type{Option{T}}) where {T} = T
Base.Iterators.reverse(o::Option) = o

# Functor. The empty branch takes its parameter from `promote_op`, as Base's `map` on an empty
# array does (ADR-0001 §4); the result is never asserted.
Base.map(f, o::Option{T}) where {T} = o.has ? some(f(_get(o))) : none(Base.promote_op(f, T))
Upstream.fmap(f, o::Option) = map(f, o)

# Applicative
Upstream.pure(::OptionTag, x) = some(x)
function Upstream.ap(ff::Option{F}, fx::Option{T}) where {F, T}
    (ff.has && fx.has) && return some(_get(ff)(_get(fx)))
    return none(Base.promote_op(_call, F, T))
end

# Monad
function Upstream.chain(f, o::Option{T}) where {T}
    o.has && return f(_get(o))::Option
    return none(_param(Option, Base.promote_op(f, T), 1))
end

# Alternative
Upstream.alt(a::Option{T}, b::Option{T}) where {T} = a.has ? a : b
Upstream.zeroalt(::OptionTag, ::Type{T}) where {T} = none(T)

# Traversable
function Upstream.traverse(tag, f, o::Option{T}) where {T}
    o.has && return Upstream.fmap(some, f(_get(o)))
    return Upstream.pure(tag, none(_valparam(Base.promote_op(f, T))))
end

Upstream.constructorclass(::Type{<:Option}) = OptionTag()
_mappedindex(::Type{<:Option}) = 1

"""
    OptionMonoid(m, T)

The monoid on `Option{T}` lifted from a semigroup instance `m` on `T`: two values are combined
with `m`, and `none(T)` is the identity. Internal until the typeclass names are settled.
"""
struct OptionMonoid{M, T}
    m::M
end
OptionMonoid(m, ::Type{T}) where {T} = OptionMonoid{typeof(m), T}(m)

function Upstream.combine(om::OptionMonoid{M, T}, a::Option{T}, b::Option{T}) where {M, T}
    a.has || return b
    b.has || return a
    return _some(T, Upstream.combine(om.m, _get(a), _get(b)))
end
Upstream.neutral(::OptionMonoid{M, T}) where {M, T} = none(T)

# Equality over the tag and the active slot only (ADR-0001 §5; spec §5).
Base.:(==)(a::Option, b::Option) = a.has == b.has && (!a.has || _get(a) == _get(b))
Base.isequal(a::Option, b::Option) = a.has == b.has && (!a.has || isequal(_get(a), _get(b)))
const _H_SOME = 0x6c0b1c3f9d2e5a71 % UInt
const _H_NONE = 0x2f8e4d1a7b3c9e05 % UInt
Base.hash(o::Option, h::UInt) = o.has ? hash(_get(o), h ⊻ _H_SOME) : hash(_H_NONE, h)

function Base.show(io::IO, o::Option{T}) where {T}
    if o.has
        print(io, "some(")
        show(io, _get(o))
    else
        print(io, "none(")
        show(io, T)
    end
    return print(io, ")")
end
