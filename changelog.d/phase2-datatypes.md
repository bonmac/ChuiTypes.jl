- Phase 2 (core data types, plus laws), per ADR-0001 and ADR-0004. New exported types and
  constructors: `Option` (`some`, `none(T)`), `Either` (`left(x, R)`, `right(L, x)`),
  `Validation` (`valid(a, E)`, `invalid(e, A)`, accumulating errors in a fresh vector), `These`
  (`this`/`that`/`both`, public but not exported), `NonEmpty` (`nonempty`) and `LazyList`
  (`lazynil`, `lazycons`, `lazylist`; memoised, not thread-safe). Accessors `issome`, `isnone`,
  `isleft`, `isright`, `fromleft`, `fromright`, `isinvalid`, `errors`, and the public
  `isthis`/`isthat`/`isboth`/`here`/`there`. Base methods: `map`, `iterate`, `length`, `get`,
  `isvalid`, `foldl`/`foldr`, `==`, `isequal`, `hash`, `show`.
- The internal `ChuiTypes.Upstream` module holds stand-ins for the typeclass operations (`fmap`,
  `pure`, `ap`, `chain`, `alt`, `zeroalt`, `bimap`, `traverse`, `combine`, `neutral`,
  `default_monoid`, `constructorclass`) following ChuiCore ADR-0001; they are not public and
  change at the switch-over to a ChuiCore snapshot. A `:quality` test keeps every ChuiCore
  mention in `src/upstream.jl`.
- Local law kits in `test/laws/` (`@check record=false` plus `@test`), law tests for every
  instance of ADR-0001 §10, and one planted violation per law that runs on Julia 1.10.
- Zero-allocation tests for `Option{Int}`, `Option{String}`, `Either{String,Int}` and
  `Validation{String,Int}` chains, `@inferred` chain tests, the CT-003 collision test, and a
  `benchmark/` suite. New dependency: Compat (`4.10`) for `@compat public`.
- ADR-0001 §4 amended (user, phase-2 ★, 2026-10-20): `LazyList` is the documented exception to
  "stale inference never costs correctness", because a lazily mapped list fixes its element
  type at `map` time.
