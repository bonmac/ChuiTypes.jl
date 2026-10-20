"""
    ChuiTypes

Data types, effects and streams for the Chui ecosystem.

Phase 2 provides the core data types (ADR-0001): [`Option`](@ref), [`Either`](@ref),
[`Validation`](@ref), [`These`](@ref), [`NonEmpty`](@ref) and [`LazyList`](@ref). They are
concrete parametric structs whose operations infer concrete types and, for isbits and string
payloads, do not allocate.

Typeclass operations (`fmap`, `pure`, `ap`, `chain`, `alt`, `zeroalt`, `bimap`, `traverse`,
`combine`, `neutral`) live in the internal module `ChuiTypes.Upstream` and are **not public**:
their names follow the upstream core package once it is released (ADR-0004), and may change.
Use the Base functions (`map`, `iterate`, `foldl`, `get`, `show`) for stable behaviour.
"""
module ChuiTypes

using Compat: @compat

export Option, some, none, issome, isnone
export Either, left, right, isleft, isright, fromleft, fromright
export Validation, valid, invalid, isinvalid, errors
export These
export NonEmpty, nonempty
export LazyList, lazylist, lazycons, lazynil

@compat public this, that, both, isthis, isthat, isboth, here, there

# Token for the inner constructors: values are built only through the documented constructors.
struct _New end
const _NEW = _New()

include("upstream.jl")
include("common.jl")
include("option.jl")
include("either.jl")
include("validation.jl")
include("these.jl")
include("nonempty.jl")
include("lazylist.jl")

end # module ChuiTypes
