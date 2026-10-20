# NonEmpty{T}: a sequence with at least one element (ADR-0001: `head::T`, `tail::Vector{T}`).

"""
    NonEmpty{T}

A sequence of at least one `T`, built with `nonempty(x, xs...)`. Stored as `head::T` and
`tail::Vector{T}`, so it is concrete (ADR-0001, SUM-11). Treat it as immutable: no operation
mutates a `NonEmpty`'s vector, and every operation that builds one copies. `map` and the other
operations never convert element values: their element type is the `typejoin` of the results'
types, as for Base's `map` (only the constructor promotes, like `[x, xs...]`).

Base integration: `iterate`, `length`, `first`, `last`, `getindex`, `map`, `foldl`/`foldr`,
`reduce` without `init` (never empty), `==`, `isequal`, `hash`, `show`.
"""
struct NonEmpty{T}
    head::T
    tail::Vector{T}
    NonEmpty{T}(::_New, head, tail::Vector{T}) where {T} = new{T}(head, tail)
end

"""
    nonempty(x, xs...)

The `NonEmpty` holding `x` followed by `xs`. The element type is the promoted type of the
arguments, as for the array literal `[x, xs...]`.
"""
function nonempty(x, xs...)
    T = promote_type(typeof(x), map(typeof, xs)...)
    return NonEmpty{T}(_NEW, x, T[xs...])
end

Base.first(ne::NonEmpty) = ne.head
Base.last(ne::NonEmpty) = isempty(ne.tail) ? ne.head : last(ne.tail)
Base.length(ne::NonEmpty) = 1 + length(ne.tail)
Base.eltype(::Type{NonEmpty{T}}) where {T} = T
Base.firstindex(::NonEmpty) = 1
Base.lastindex(ne::NonEmpty) = length(ne)
Base.getindex(::NonEmpty, i::Bool) = throw(ArgumentError("invalid index: $i of type Bool"))
function Base.getindex(ne::NonEmpty, i::Integer)
    i == 1 && return ne.head
    checkbounds(Bool, ne.tail, i - 1) || throw(BoundsError(ne, i))
    return @inbounds ne.tail[i - 1]
end
function Base.iterate(ne::NonEmpty, i::Int = 1)
    i == 1 && return (ne.head, 2)
    i - 1 <= length(ne.tail) || return nothing
    return (@inbounds(ne.tail[i - 1]), i + 1)
end
Base.Iterators.reverse(ne::NonEmpty) = Base.Iterators.reverse(collect(ne))

# Build a NonEmpty{U} from a head and a tail whose elements are all `<: U`. `U` is always a
# `typejoin` of the element types, so the `convert`s below never change a value.
_ne(::Type{U}, head, tail) where {U} = NonEmpty{U}(_NEW, head, convert(Vector{U}, tail))

# Functor. The element type is the `typejoin` (never `promote_type`: values are not converted)
# of the head's result type and `map`'s eltype for the tail; for an empty tail that eltype comes
# from inference (ADR-0001 §4), never asserted.
function Base.map(f, ne::NonEmpty)
    h = f(ne.head)
    t = map(f, ne.tail)
    return _ne(typejoin(typeof(h), eltype(t)), h, t)
end
Upstream.fmap(f, ne::NonEmpty) = map(f, ne)

_neparam(::Type{NonEmpty{T}}) where {T} = T
_neparam(::Type) = Any

# Monad: concatenation of the results (element type by `typejoin`, as for `map`)
function Upstream.chain(f, ne::NonEmpty)
    r = f(ne.head)::NonEmpty
    parts = map(f, ne.tail)
    U = typejoin(eltype(r), _neparam(eltype(parts)))
    out = Vector{U}(r.tail)
    for p in parts
        p::NonEmpty
        push!(out, p.head)
        append!(out, p.tail)
    end
    return NonEmpty{U}(_NEW, r.head, out)
end

# Applicative
Upstream.pure(::NonEmptyTag, x) = nonempty(x)
Upstream.ap(fs::NonEmpty, xs::NonEmpty) = Upstream.chain(f -> map(f, xs), fs)

# Traversable: left to right, through the target applicative's `fmap` and `ap`. The results
# are collected in an immutable reversed list (shared safely when the target applicative runs a
# function more than once), so the traversal is linear; the vector is built once at the end.
struct _RevNode
    v::Any
    next::Union{Nothing, _RevNode}
end
function _ne_from_rev(n::_RevNode)
    xs = Any[]
    while true
        push!(xs, n.v)
        next = n.next
        next === nothing && break
        n = next
    end
    v = [x for x in Iterators.reverse(xs)]   # Base's widening: the tightest element type
    return NonEmpty{eltype(v)}(_NEW, v[1], v[2:end])
end
function Upstream.traverse(tag, f, ne::NonEmpty)
    acc = Upstream.fmap(y -> _RevNode(y, nothing), f(ne.head))
    for x in ne.tail
        acc = Upstream.ap(Upstream.fmap(n -> (y -> _RevNode(y, n)), acc), f(x))
    end
    return Upstream.fmap(_ne_from_rev, acc)
end

Upstream.constructorclass(::Type{<:NonEmpty}) = NonEmptyTag()
_mappedindex(::Type{<:NonEmpty}) = 1

"""
    NonEmptySemigroup()

Concatenation semigroup on `NonEmpty`; the result owns a fresh vector. Internal until the
typeclass names are settled.
"""
struct NonEmptySemigroup end

function Upstream.combine(::NonEmptySemigroup, a::NonEmpty{S}, b::NonEmpty{T}) where {S, T}
    U = promote_type(S, T)
    return NonEmpty{U}(_NEW, a.head, U[a.tail; b.head; b.tail])
end

Base.:(==)(a::NonEmpty, b::NonEmpty) = (a.head == b.head) & (a.tail == b.tail)
Base.isequal(a::NonEmpty, b::NonEmpty) = isequal(a.head, b.head) && isequal(a.tail, b.tail)
const _H_NONEMPTY = 0x58e3b1d7c2a96f40 % UInt
Base.hash(ne::NonEmpty, h::UInt) = hash(ne.tail, hash(ne.head, h ⊻ _H_NONEMPTY))

function Base.show(io::IO, ne::NonEmpty)
    print(io, "nonempty(")
    for (i, x) in enumerate(ne)
        i > 1 && print(io, ", ")
        show(io, x)
    end
    return print(io, ")")
end
