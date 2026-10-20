# LazyList{T}: a memoised lazy cons list (ADR-0001 §7). For laziness and infinite lists, not
# for bulk data (streams, ADR-0003, are the bulk path).

const _UNFORCED = 0x00
const _EMPTY = 0x01
const _CONS = 0x02
const _FORCING = 0x03

# A cell is forced at most once. `thunk` is a zero-argument callable returning `nothing` (the
# list ends) or a tuple `(head, rest::LazyList{T})`; it is dropped after forcing.
mutable struct _LazyCell{T}
    state::UInt8
    head::Union{Nothing, T}
    tail::Union{Nothing, _LazyCell{T}}
    thunk::Any
    # Only the parametric constructor: the default outer one has an unbound `T` (Aqua, on 1.10).
    _LazyCell{T}(state, head, tail, thunk) where {T} = new{T}(state, head, tail, thunk)
end

"""
    LazyList{T}

A lazy, memoised cons list of `T`, possibly infinite. Built with [`lazynil`](@ref),
[`lazycons`](@ref) or [`lazylist`](@ref). `map`, `chain`, `ap` and `alt` are lazy: nothing is
computed until a cell is forced (by iteration), and each cell is forced once.

- **Not thread-safe** in v0.1: forcing the same unforced cell from two tasks at once is a data
  race (ADR-0001 §7).
- `map`/`chain`/`ap` fix the result element type from `Base.promote_op` when they are called
  (ADR-0001 §4). A method defined between that call and forcing, which changes the function's
  return type, can make forcing throw a conversion error (the documented exception of the
  ADR-0001 §4 amendment, 2026-10-20).
- `length`, `==`, `isequal`, `hash` and `foldl` force the whole list (they do not return on an
  infinite list). `Base.IteratorSize` is `SizeUnknown`, so `Iterators.take` works on infinite
  lists.
- Forcing a cell runs the thunks of the lists it was built from, recursively: a list built by
  very deeply nested `map`s or left-nested `alt`s (around 10^5 levels) overflows the stack on
  its first force. Runs of empty results in `chain` are skipped in a loop, not by recursion.
- A cell whose thunk forces that same cell (a list defined in terms of itself without a delay)
  throws an `ArgumentError`. A thunk that throws leaves its cell unforced, so forcing again
  retries.
"""
struct LazyList{T}
    cell::_LazyCell{T}
end

_lazy(::Type{T}, thunk) where {T} = LazyList{T}(_LazyCell{T}(_UNFORCED, nothing, nothing, thunk))

"""
    lazynil(T)

The empty `LazyList{T}`.
"""
lazynil(::Type{T}) where {T} = LazyList{T}(_LazyCell{T}(_EMPTY, nothing, nothing, nothing))

"""
    lazycons(x, rest)

The list with head `x` followed by `rest`. `rest` is a `LazyList{T}` (the result is a
`LazyList{T}`), or a zero-argument function returning a `LazyList{typeof(x)}`, called only when
the tail is first needed (so a list can refer to itself: `ones = lazycons(1, () -> ones)`).
"""
lazycons(x, rest::LazyList{T}) where {T} = LazyList{T}(_LazyCell{T}(_CONS, convert(T, x), rest.cell, nothing))
function lazycons(x, rest)
    T = typeof(x)
    return LazyList{T}(_LazyCell{T}(_CONS, x, _lazy(T, () -> _uncons(rest()::LazyList{T})).cell, nothing))
end

"""
    lazylist(itr)

A `LazyList{eltype(itr)}` over `itr`, which is iterated lazily and at most once (the cells are
memoised). `itr` may be infinite.
"""
lazylist(itr) = _lazy(eltype(itr), () -> _fromiter(eltype(itr), itr, iterate(itr)))
function _fromiter(::Type{T}, itr, y) where {T}
    y === nothing && return nothing
    x, s = y
    return (x, _lazy(T, () -> _fromiter(T, itr, iterate(itr, s))))
end

function _force!(c::_LazyCell{T}) where {T}
    c.state == _FORCING &&
        throw(ArgumentError("a LazyList cell was forced while it was being forced: the list refers to itself without a delay"))
    if c.state == _UNFORCED
        c.state = _FORCING
        try
            r = c.thunk()
            if r === nothing
                c.state = _EMPTY
            else
                x, rest = r
                c.head = x
                c.tail = (rest::LazyList{T}).cell
                c.state = _CONS
            end
        catch
            c.state = _UNFORCED
            rethrow()
        end
        c.thunk = nothing
    end
    return c
end

# `nothing` if `l` is empty, else `(head, tail)`.
function _uncons(l::LazyList{T}) where {T}
    c = _force!(l.cell)
    c.state == _EMPTY && return nothing
    return (c.head::T, LazyList{T}(c.tail::_LazyCell{T}))
end

function Base.iterate(l::LazyList{T}, c::_LazyCell{T} = l.cell) where {T}
    _force!(c)
    c.state == _EMPTY && return nothing
    return (c.head::T, c.tail::_LazyCell{T})
end
Base.IteratorSize(::Type{<:LazyList}) = Base.SizeUnknown()
Base.eltype(::Type{LazyList{T}}) where {T} = T
Base.isempty(l::LazyList) = _force!(l.cell).state == _EMPTY
function Base.length(l::LazyList)
    n = 0
    for _ in l
        n += 1
    end
    return n
end
Base.Iterators.reverse(l::LazyList) = Base.Iterators.reverse(collect(l))

# Lazy append of `a` (any element type) and `b`, as a LazyList{S}.
function _append(::Type{S}, a::LazyList, b::LazyList{S}) where {S}
    return _lazy(
        S, () -> begin
            u = _uncons(a)
            u === nothing ? _uncons(b) : (u[1], _append(S, u[2], b))
        end
    )
end

# Functor
_map(f, ::Type{S}, l::LazyList) where {S} = _lazy(
    S, () -> begin
        u = _uncons(l)
        u === nothing ? nothing : (f(u[1]), _map(f, S, u[2]))
    end
)
Base.map(f, l::LazyList{T}) where {T} = _map(f, Base.promote_op(f, T), l)
Upstream.fmap(f, l::LazyList) = map(f, l)

# Monad: lazy concat-map. Runs of empty inner lists are skipped in a loop, not by recursion.
_chain(f, ::Type{S}, l::LazyList) where {S} = _lazy(S, () -> _chainstep(f, S, l))
function _chainstep(f, ::Type{S}, l::LazyList) where {S}
    while true
        u = _uncons(l)
        u === nothing && return nothing
        x, rest = u
        inner = _uncons(f(x)::LazyList)
        inner === nothing || return (inner[1], _append(S, inner[2], _chain(f, S, rest)))
        l = rest
    end
    return nothing
end
Upstream.chain(f, l::LazyList{T}) where {T} = _chain(f, _param(LazyList, Base.promote_op(f, T), 1), l)

# Applicative
Upstream.pure(::LazyListTag, x) = lazycons(x, lazynil(typeof(x)))
function Upstream.ap(fs::LazyList{F}, xs::LazyList{T}) where {F, T}
    S = Base.promote_op(_call, F, T)
    return _chain(f -> _map(f, S, xs), S, fs)
end

# Alternative (lazy append)
Upstream.alt(a::LazyList{T}, b::LazyList{T}) where {T} = _append(T, a, b)
Upstream.zeroalt(::LazyListTag, ::Type{T}) where {T} = lazynil(T)

Upstream.constructorclass(::Type{<:LazyList}) = LazyListTag()
_mappedindex(::Type{<:LazyList}) = 1

"""
    LazyListMonoid(T)

Monoid on `LazyList{T}`: lazy append, with `lazynil(T)` (a fresh list on every call) as the
identity. Internal until the typeclass names are settled.
"""
struct LazyListMonoid{T} end
LazyListMonoid(::Type{T}) where {T} = LazyListMonoid{T}()
Upstream.combine(::LazyListMonoid{T}, a::LazyList{T}, b::LazyList{T}) where {T} = _append(T, a, b)
Upstream.neutral(::LazyListMonoid{T}) where {T} = lazynil(T)

# Equality and hash force both lists.
function _eqby(eq, a::LazyList, b::LazyList)
    ya, yb = iterate(a), iterate(b)
    result = true
    while ya !== nothing && yb !== nothing
        r = eq(ya[1], yb[1])
        r === false && return false
        result = result & r
        ya, yb = iterate(a, ya[2]), iterate(b, yb[2])
    end
    return (ya === nothing && yb === nothing) ? result : false
end
Base.:(==)(a::LazyList, b::LazyList) = _eqby(==, a, b)
Base.isequal(a::LazyList, b::LazyList) = _eqby(isequal, a, b)
const _H_LAZYLIST = 0x0e9b4c7a3f1d6258 % UInt
function Base.hash(l::LazyList, h::UInt)
    h = h ⊻ _H_LAZYLIST
    for x in l
        h = hash(x, h)
    end
    return h
end

# `show` never forces: it prints the forced prefix, at most `_SHOW_MAX` elements (a forced
# cyclic list, such as `ones = lazycons(1, () -> ones)`, has no end).
const _SHOW_MAX = 20
function Base.show(io::IO, l::LazyList{T}) where {T}
    c = l.cell
    if c.state == _EMPTY
        print(io, "lazynil(")
        show(io, T)
        return print(io, ")")
    end
    xs = T[]
    while c.state == _CONS && length(xs) < _SHOW_MAX
        push!(xs, c.head::T)
        c = c.tail::_LazyCell{T}
    end
    if c.state == _EMPTY
        print(io, "lazylist(")
        show(io, xs)
        return print(io, ")")
    end
    print(io, "LazyList{")
    show(io, T)
    print(io, "}(")
    if isempty(xs)
        print(io, "…")
    else
        print(io, "[")
        join(io, (repr(x) for x in xs), ", ")
        print(io, ", …]")
    end
    return print(io, ")")
end
