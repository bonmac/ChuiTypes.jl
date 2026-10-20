# Shared helpers: the result-parameter rule of ADR-0001 §4 and the constructor tags.

# `promote_op(_call, F, T)` is the result type of applying a function of type `F` to a `T`.
_call(f, x) = f(x)

"""
    _param(W, R, i)

ADR-0001 §4: the `i`-th parameter of `R` when `R` is a concrete `W`, else `Any`. `R` comes from
`Base.promote_op` and is **never asserted**: stale inference costs precision, not correctness.
`Union{}` (the function always throws), a `Union` of `W`s and `Any` all give `Any`.
"""
@inline _param(::Type{W}, R, i::Int) where {W} =
    (R isa DataType && R <: W && isconcretetype(R)) ? R.parameters[i] : Any

# Index of the parameter a constructor class maps over, for `_valparam`; each type file adds one.
_mappedindex(::Type) = 0

"""
    _valparam(R)

The mapped-over parameter of `R` (the `T` of `Option{T}`, the `R` of `Either{L,R}`, …) when
`R` is a concrete ChuiTypes type, else `Any` (same rule as `_param`). `traverse` uses it to type
an empty or left result.
"""
@inline function _valparam(R)
    R isa DataType && isconcretetype(R) || return Any
    i = _mappedindex(R)
    return i == 0 ? Any : R.parameters[i]
end

# Constructor tags (spec §2). A tag fixes every parameter except the mapped-over one, so the
# value-less operations (`pure`, `zeroalt`, `traverse`'s empty branch) are type-stable.

"Constructor tag of `Option`."
struct OptionTag end
"Constructor tag of `Either{L,⋅}`."
struct EitherTag{L} end
"Constructor tag of `Validation{E,⋅}`."
struct ValidationTag{E} end
"Constructor tag of `These{A,⋅}`."
struct TheseTag{A} end
"Constructor tag of `NonEmpty`."
struct NonEmptyTag end
"Constructor tag of `LazyList`."
struct LazyListTag end
