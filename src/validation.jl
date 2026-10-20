# Validation{E,A}: a valid value or accumulated errors (ADR-0001 §2, §6).

const _INVALID = 0x00
const _VALID = 0x01

"""
    Validation{E,A}

Either `valid(a, E)` or invalid with one or more errors of type `E`. Errors accumulate: the
applicative `ap` of two invalid values keeps both error lists, in a **fresh** `Vector{E}`; no
operation mutates an input's vector (ADR-0001 §6). There is no Monad instance, because a
monadic `ap` would stop at the first error (ADR-0001 §10).

A concrete struct with a `UInt8` tag, `errs::Union{Nothing,Vector{E}}` (`nothing` when valid,
so a valid value allocates nothing) and `a::Union{Nothing,A}`.

`isvalid(v)` (a `Base.isvalid` method) and `isinvalid(v)` test the variant; `errors(v)` returns
a copy of the errors.
"""
struct Validation{E, A}
    tag::UInt8
    errs::Union{Nothing, Vector{E}}
    a::Union{Nothing, A}
    Validation{E, A}(::_New, tag::UInt8, errs, a) where {E, A} = new{E, A}(tag, errs, a)
end

"""
    valid(a, E)

The valid `Validation{E,typeof(a)}` holding `a`. The error type `E` is required (ADR-0001 §3).
"""
valid(a, ::Type{E}) where {E} = Validation{E, typeof(a)}(_NEW, _VALID, nothing, a)

"""
    invalid(e, A)

The invalid `Validation{typeof(e),A}` with the single error `e`. The value type `A` is required
(ADR-0001 §3). Several errors arise by combining invalid values (`ap`, `ValidationSemigroup`).
"""
invalid(e, ::Type{A}) where {A} = Validation{typeof(e), A}(_NEW, _INVALID, typeof(e)[e], nothing)

# Internal: `errs` is shared, never mutated, by every operation below.
_invalid(errs::Vector{E}, ::Type{A}) where {E, A} = Validation{E, A}(_NEW, _INVALID, errs, nothing)
_valid(::Type{E}, ::Type{A}, a) where {E, A} = Validation{E, A}(_NEW, _VALID, nothing, a)
_errs(v::Validation{E}) where {E} = v.errs::Vector{E}
_geta(v::Validation{E, A}) where {E, A} = v.a::A

"""
    isvalid(v::Validation) -> Bool

Whether `v` is valid. A method of `Base.isvalid`.
"""
Base.isvalid(v::Validation) = v.tag == _VALID

"""
    isinvalid(v::Validation) -> Bool

Whether `v` holds errors.
"""
isinvalid(v::Validation) = v.tag == _INVALID

"""
    errors(v::Validation{E}) -> Vector{E}

A fresh copy of `v`'s errors, empty when `v` is valid.
"""
errors(v::Validation{E}) where {E} = isinvalid(v) ? copy(_errs(v)) : E[]

Base.get(v::Validation, default) = isvalid(v) ? _geta(v) : default

Base.iterate(v::Validation, done::Bool = false) = (isvalid(v) && !done) ? (_geta(v), true) : nothing
Base.length(v::Validation) = Int(isvalid(v))
Base.eltype(::Type{Validation{E, A}}) where {E, A} = A
Base.Iterators.reverse(v::Validation) = v

# Functor
function Base.map(f, v::Validation{E, A}) where {E, A}
    isvalid(v) && return valid(f(_geta(v)), E)
    return _invalid(_errs(v), Base.promote_op(f, A))
end
Upstream.fmap(f, v::Validation) = map(f, v)

# Applicative, accumulating errors in a fresh vector
Upstream.pure(::ValidationTag{E}, x) where {E} = valid(x, E)
function Upstream.ap(ff::Validation{E, F}, fx::Validation{E, T}) where {E, F, T}
    (isvalid(ff) && isvalid(fx)) && return valid(_geta(ff)(_geta(fx)), E)
    S = Base.promote_op(_call, F, T)
    isvalid(ff) && return _invalid(_errs(fx), S)
    isvalid(fx) && return _invalid(_errs(ff), S)
    return _invalid(vcat(_errs(ff), _errs(fx)), S)
end

# Bifunctor: `f` over each error, `g` over the value
function Upstream.bimap(f, g, v::Validation{E, A}) where {E, A}
    isvalid(v) && return valid(g(_geta(v)), Base.promote_op(f, E))
    return _invalid(map(f, _errs(v)), Base.promote_op(g, A))
end

# Traversable
function Upstream.traverse(tag, f, v::Validation{E, A}) where {E, A}
    isvalid(v) && return Upstream.fmap(y -> valid(y, E), f(_geta(v)))
    return Upstream.pure(tag, _invalid(_errs(v), _valparam(Base.promote_op(f, A))))
end

Upstream.constructorclass(::Type{Validation{E, A}}) where {E, A} = ValidationTag{E}()
_mappedindex(::Type{<:Validation}) = 2

"""
    ValidationSemigroup(m)

Semigroup on `Validation{E,A}`: two valid values are combined with the semigroup instance `m`
on `A`; errors are concatenated into a fresh vector. Internal until the typeclass names are
settled.
"""
struct ValidationSemigroup{M}
    m::M
end

function Upstream.combine(s::ValidationSemigroup, a::Validation{E, A}, b::Validation{E, A}) where {E, A}
    (isvalid(a) && isvalid(b)) && return _valid(E, A, Upstream.combine(s.m, _geta(a), _geta(b)))
    isvalid(a) && return b
    isvalid(b) && return a
    return _invalid(vcat(_errs(a), _errs(b)), A)
end

function Base.:(==)(a::Validation, b::Validation)
    a.tag == b.tag || return false
    return isvalid(a) ? _geta(a) == _geta(b) : _errs(a) == _errs(b)
end
function Base.isequal(a::Validation, b::Validation)
    a.tag == b.tag || return false
    return isvalid(a) ? isequal(_geta(a), _geta(b)) : isequal(_errs(a), _errs(b))
end
const _H_VALID = 0x3e6a9c1f5b8d2047 % UInt
const _H_INVALID = 0xa5d81f3c7e2b9046 % UInt
Base.hash(v::Validation, h::UInt) =
    isvalid(v) ? hash(_geta(v), h ⊻ _H_VALID) : hash(_errs(v), h ⊻ _H_INVALID)

function Base.show(io::IO, v::Validation{E, A}) where {E, A}
    if isvalid(v)
        print(io, "valid(")
        show(io, _geta(v))
        print(io, ", ")
        show(io, E)
        print(io, ")")
    elseif length(_errs(v)) == 1
        print(io, "invalid(")
        show(io, only(_errs(v)))
        print(io, ", ")
        show(io, A)
        print(io, ")")
    else
        # several errors have no one-constructor syntax (spec §7)
        print(io, "Validation{")
        show(io, E)
        print(io, ", ")
        show(io, A)
        print(io, "}(errors = ")
        show(io, _errs(v))
        print(io, ")")
    end
    return nothing
end
