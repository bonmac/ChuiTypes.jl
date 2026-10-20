"""
    ChuiTypes.Upstream

The one adapter to ChuiCore (ADR-0004). This is the **only** file in `src/` and `ext/` that may
name ChuiCore; a `:quality` test enforces it.

ChuiCore has no registered snapshot yet, so every function below is a local **stand-in**: an
empty generic function that the type files extend with `Upstream.f(...) = ...`. When a ChuiCore
snapshot provides the same name and signature, the stand-in becomes `using ChuiCore: f` (or
`const f = ChuiCore.g` for a rename) in this file only (ADR-0004 §3).

Names and conventions mirror ChuiCore ADR-0001 (accepted): Semigroup/Monoid are instance values
(`combine(m, a, b)`, `neutral(m)` fresh on every call); constructor classes are keyed on an owned
tag, and operations with no value to dispatch on take the tag first (`pure(tag, x)`). Names
ChuiCore has not fixed (`chain`, `ap`, `alt`, `zeroalt`, `bimap`) are ChuiTypes proposals
(request R1).

None of these names is exported or public: they may change at the switch-over.
"""
module Upstream

"""
    fmap(f, x)

Functor map (ChuiCore ADR-0001 §3). On every ChuiTypes type it is the same as `Base.map(f, x)`.
"""
function fmap end

"""
    pure(tag, x)

Applicative unit: wraps `x` in the constructor named by `tag` (ChuiCore ADR-0001 §3).
"""
function pure end

"""
    ap(ff, fx)

Applicative apply: applies the function(s) inside `ff` to the value(s) inside `fx`.
Proposal (request R1).
"""
function ap end

"""
    chain(f, x)

Monad bind: `f` maps a value to the same constructor. Proposal (request R1); not `flatmap`,
which `Base.Iterators` owns (ChuiCore ADR-0001 §3).
"""
function chain end

"""
    alt(x, y)

Alternative choice (`<|>`). Proposal (request R1).
"""
function alt end

"""
    zeroalt(tag, T)

Alternative empty value of element type `T` for the constructor named by `tag`. Proposal
(request R1; ChuiCore ADR-0001 §3 names a `zeroalt(tag)`-style operation).
"""
function zeroalt end

"""
    bimap(f, g, x)

Bifunctor map: `f` over the first (left, error, `this`) side, `g` over the second.
Proposal (request R1).
"""
function bimap end

"""
    traverse(tag, f, x)

Traversable traverse: `f` maps each element to the applicative named by `tag`; the result is
that applicative of `x`'s shape (ChuiCore ADR-0001 §3).
"""
function traverse end

"""
    combine(m, a, b)

Semigroup operation of the instance value `m` on its carrier (ChuiCore ADR-0001 §1; the same
binding as the aggregation protocol's `combine(agg, a, b)`).
"""
function combine end

"""
    neutral(m)

Identity of the monoid instance `m`. Returns a fresh value on every call (ChuiCore ADR-0001 §1).
"""
function neutral end

"""
    default_monoid(::Type{T})

The monoid instance used for `T` when none is passed (ChuiCore ADR-0001 §1, closed sugar).
ChuiTypes declares none: `These`' Applicative/Monad need one for their first parameter. Without
a declaration it throws an `ArgumentError` naming `T`.
"""
default_monoid(::Type{T}) where {T} =
    throw(ArgumentError("no default monoid is declared for $T: declare `default_monoid(::Type{$T})`"))

"""
    constructorclass(::Type{T})

Maps a concrete type to its owned constructor tag (ChuiCore ADR-0001 §3).
"""
function constructorclass end

end # module Upstream
