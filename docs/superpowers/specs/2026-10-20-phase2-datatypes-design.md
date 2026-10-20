# Phase 2 design: core data types, plus laws

- **Status:** working design for the `phase2-datatypes` lane (T2). Binding inputs: ADR-0001,
  ADR-0004, ADR-0005 (accepted 2026-10-20), ChuiCore ADR-0001 (accepted, ChuiCore `8082735`),
  ecosystem ADR-0007 §2 amendment (`@check record=false` plus `@test`).
- **Plan:** `docs/superpowers/plans/2026-10-20-phase2-datatypes.md`.

This note records only what the ADRs leave open. Everything else follows the ADRs.

## 1. Upstream stand-ins (ADR-0004 §2)

`src/upstream.jl` declares empty generic functions. Only `neutral`, `combine(m, a, b)`,
`default_monoid`, `constructorclass`, `fmap`, `pure(tag, x)` and `traverse(tag, f, xs)` follow
names that ChuiCore ADR-0001 uses. The others are ChuiTypes proposals (request R1):

| Stand-in | Class | Note |
|---|---|---|
| `fmap(f, x)` | Functor | `Base.map` is the same operation on every owned type |
| `pure(tag, x)`, `ap(ff, fx)` | Applicative | tag first (ChuiCore ADR-0001 §3) |
| `chain(f, x)` | Monad | not `flatmap`: `Base.Iterators.flatmap` exists (ChuiCore L-2) |
| `zeroalt(tag, T)`, `alt(x, y)` | Alternative | the empty value takes its element type, like `none(T)` |
| `bimap(f, g, x)` | Bifunctor | |
| `traverse(tag, f, x)` | Traversable | `tag` is the result applicative's tag |
| `combine(m, a, b)`, `neutral(m)` | Semigroup, Monoid | instance values; `neutral` fresh per call |
| `default_monoid(T)` | Monoid sugar | used by `These`' Applicative/Monad on `A` |
| `constructorclass(T)` | trait map | type → owned tag |

Foldable is Base iteration (ChuiCore ADR-0001 §3): `iterate`, `length`, `foldl`, `foldr`
(through `Iterators.reverse`), `mapreduce`. No stand-in.

Not mirrored: ChuiCore's style traits (`FunctorStyle(tag)` …) and its `NoTag` fallback. Their
phase-2 names are not fixed yet, so instances are plain methods on the owned types. Adopting the
style traits is the planned multi-file change of ADR-0004 §3.

## 2. Tags carry the fixed parameters

A tag fixes every type parameter except the one the class maps over, so value-less operations
are type-stable: `OptionTag()`, `EitherTag{L}()`, `ValidationTag{E}()`, `TheseTag{A}()`,
`NonEmptyTag()`, `LazyListTag()`. `constructorclass(Either{L,R}) === EitherTag{L}()`.

## 3. Instance values (Semigroup/Monoid)

Owned, unexported, not public until ChuiCore's names land:
`OptionMonoid(m, T)` (lifts a semigroup `m` on `T`; `neutral` is `none(T)`),
`ValidationSemigroup(m)` (combines valid values with `m`, concatenates errors),
`NonEmptySemigroup()` (concatenation), `LazyListMonoid(T)` (lazy append; `neutral` is
`lazynil(T)`). `These`' Applicative/Monad combine `A` values with
`combine(default_monoid(A), a1, a2)`, so they exist only for `A` with a `default_monoid`.

## 4. Public surface

- **Exported:** the six types; `some`, `none`, `issome`, `isnone`; `left`, `right`, `isleft`,
  `isright`, `fromleft`, `fromright`; `valid`, `invalid`, `isinvalid`, `errors`; `nonempty`;
  `lazylist`, `lazycons`, `lazynil`. Base methods: `map`, `iterate`, `length`, `eltype`,
  `foldl`/`foldr`, `get`, `isvalid` (on `Validation`), `first`/`last`/`getindex` (on `NonEmpty`),
  `==`, `isequal`, `hash`, `show`.
- **Public, not exported** (`@compat public`, HANDOFF decision 3): `this`, `that`, `both`,
  `isthis`, `isthat`, `isboth`, `here`, `there`.
- **Internal** (may change at the ChuiCore switch-over): `Upstream` and its functions, the tags,
  the instance values.

## 5. Equality

`==`, `isequal` and `hash` look at the variant and the active slots only, not at the type
parameters: `none(Int) == none(String)`, as `Int[] == String[]` in Base.

## 6. `LazyList`

`lazynil(T)`, `lazycons(x, rest)` (`rest` a `LazyList` or a zero-argument function returning
one; the head is converted to `T` when the list is built) and `lazylist(itr)` (lazy over any
iterator, consumed once). Cells are memoised and forcing is not thread-safe (ADR-0001 §7). A cell
that forces itself throws an `ArgumentError`; a thunk that throws leaves its cell unforced.

**Exception to ADR-0001 §4, decided: the user chose option (a) at the phase-2 ★ (2026-10-20,
relayed to the lane by the lead),
and ADR-0001 §4 now carries the amendment.** `map`/`chain`/`ap` fix the result element
type from `promote_op` when they are called, and later store computed values in cells of that
type. A method added between `map` and forcing that changes `f`'s return type therefore makes
forcing throw (`g(x) = 1; l = map(g, lazylist(1:3)); @eval g(x) = 1.5; collect(l)` gives an
`InexactError`). ADR-0001 §4 says a stale inferred parameter costs precision, "never
correctness". Every other type here stores values computed eagerly, so only `LazyList` is
affected. The two ways out are an ADR-0001 amendment naming `LazyList` as the exception (the
lane's recommendation: it is a corner case of world-age changes during a lazy computation,
documented in the docstring), or element type `Any` for lazily mapped lists, which gives up type
stability on iteration.

## 6a. Element types never convert values

`NonEmpty`'s `map`, `chain` and `traverse` pick the element type by `typejoin` (Base's `map`
widens the same way), never by `promote_type`: `map(x -> x == 1 ? 1 : 2.5, nonempty(1, 2))`
keeps the `Int` 1 and has element type `Real`. Only the constructor `nonempty(x, xs...)` and
`NonEmptySemigroup` promote, like the array literal and `vcat`. `Validation`'s `bimap` takes the
new error type from `promote_op(f, E)` on both branches. `Either`/`These` `chain` require the
continuation to keep the fixed parameter (`::Either{L}`, `::These{A}`).

## 7. `Validation` show

One error prints as `invalid(e, A)`. Several errors have no single-constructor syntax (ADR-0001
§3 allows one constructor per variant), so they print as `Validation{E, A}(errors = [...])`.

## 8. The ChuiCore grep test and its blind spots

`test/test_quality.jl` greps `src/` and `ext/` for `\bChuiCore\b` outside `src/upstream.jl`.
Blind spots: names built at run time (`getfield(Main, Symbol("Chui", "Core"))`, `eval`), and a
module reached through `Base.loaded_modules`. ADR-0004 §1 asks for these to be listed in
`docs/CHECK_COVERAGE.md`; that file is generated from `.agents/checks.local.toml`, outside this
lane's scope, so the lead is asked to add the row.
