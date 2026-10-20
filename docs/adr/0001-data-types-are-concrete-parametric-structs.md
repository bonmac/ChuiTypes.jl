# ADR-0001: Data types are concrete parametric structs with one slot per variant payload

- **Status:** Accepted (2026-10-20, user at the ChuiTypes phase-1 ★); amended 2026-10-20 (§4,
  `LazyList` exception: the user's answer to the phase-2 ★ decision 0, relayed by the lead)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint (via the lead)
- **Scope:** ChuiTypes.jl

## Context

Brief 20 lists the data types `Option`/`Maybe`, `Either`/`Result`, `Validation`, `These`,
`NonEmpty`, `LazyList`, `Reader`, `Writer`, `State` and an IO type. They must be type-stable:
`map`/`flatmap`/`fold` chains should infer a concrete type and should not allocate. The facts below
were measured on 1.13.2 and 1.10.12 ([`docs/research/sum-types.md`](../research/sum-types.md);
evidence files in `.lanes/evidence/`).

- **Bare unions and abstract supertypes widen.** `map`/`flatmap` infer a `Union`, and an
  ordinary comprehension widens to `Vector{Any}` or to the abstract eltype. That costs about 1.5
  allocations per element and makes the code 10–100× slower (SUM-06, SUM-07). MLStyle `@data`
  cannot express a generic `None` (SUM-05).
- **One `Union` field holding all variants boxes pointer payloads.** This is the layout
  SumTypes, Moshi and ErrorTypes generate.
  - A 3-step chain over `Either{String,Int}` allocates 1.5–3 M times per 10^6 values (SUM-08).
  - So does `Option{String}`: wrapped `x::Union{_None,_Some{String}}` allocates 800000 bytes per
    10^5 values, one 16-byte box per `some`. With one slot per payload,
    `(has::Bool, v::Union{Nothing,T})`, the count is 0 (`opt2-{113,110}`; reproducer from the
    critic's review).
  - The two-slot `Option{Int}` is stored inline, makes 0 allocations, takes 24 bytes and infers
    `map` concretely. `Option{Nothing}` still tells `some(nothing)` from `none(Nothing)`
    (`opt2b-{113,110}`). The wrapped `Option{Int}` takes 16 bytes (SUM-04).
  - A `Bool` tag plus an *undefined* payload field is not stored inline for non-isbits `T`
    (SUM-04).
- **Empty and left values need the missing type** to be stable (SUM-09).
- **Validation:** errors kept in a `Vector{E}` stay concrete, while a growing tuple is not
  (SUM-10).
- **NonEmpty** (`head::T`, `tail::Vector{T}`) is concrete (SUM-11).
- **Closure-specialised `State{F}`** stops inferring at depth 3 (SUM-12). **A thunk `LazyList`**
  allocates about 95 B per element (SUM-13).
- **`Base.promote_op` cannot fix a public type.** Its result depends on the world age and on the
  packages loaded. A method added later makes an assertion against it throw on a correct program
  (`TypeError(:typeassert, …, Int64, "late")` on both versions; `polate-{113,110}`). It is also
  not `public` (`Base.ispublic(Base, :promote_op) == false` on 1.13.2).
- **Names (CT-003).** `IO` and `Task` are exported by Base/Core, and `Future` by Distributed
  (`names-{113,110}`). Every type and constructor name below is free in Base, Core and the 29
  loaded stdlibs on both versions (`ctor-names-{113,110}`).

## Decision

1. **Every value type is a concrete parametric struct** whose parameters fix the payload types.
   Two shapes are forbidden: an exported abstract type with variant subtypes, and a `Union` alias.
2. **One slot per variant payload, each typed `Union{Nothing,X}`, plus a `UInt8` tag** (one
   `Bool` for `Option`). The slot of an inactive variant holds `nothing`.
   - `Option{T}`: `has::Bool`, `v::Union{Nothing,T}`.
   - `Either{L,R}`: `tag`, `l`, `r`.
   - `Validation{E,A}`: `tag`, `errs::Union{Nothing,Vector{E}}` (`nothing` when valid), `a::Union{Nothing,A}`.
     An empty `Vector` per valid value would allocate 32–48 B each (`validalloc-{113,110}`).
   - `These{A,B}`: `tag ∈ {this, that, both}`, `a`, `b`.
3. **Constructors carry the missing type, in the position it takes in the type:**
   - `some(x)`, `none(T)`;
   - `left(x, R)` gives `Either{typeof(x),R}` and `right(L, x)` gives `Either{L,typeof(x)}`;
   - `valid(a, E)`, `invalid(e, A)`;
   - `this(a, B)`, `that(A, b)`, `both(a, b)`;
   - `nonempty(x, xs...)`.

   There is one constructor per variant: no `Option{T}()` and no alias pairs (`Maybe`, `Result`).
4. **Result types for empty or left branches.**
   - `map(f, none(T))` and the left branch of `map` on `Either` take the new parameter from
     `Base.promote_op`, the same mechanism Base uses for `map` on empty arrays.
   - `flatmap` (and the left or invalid branch of `Either` and `Validation`) extracts the
     parameter from `R = promote_op(f, T)` by one rule:
     `B = (R isa DataType && R <: Option && isconcretetype(R)) ? R.parameters[1] : Any`, and the
     same for the other types. `Union{}` (`f` always throws), a `Union` of `Option`s and `Any`
     all give `B = Any`. Those three cases are `:quality` tests.
   - The result is **never asserted**, so stale inference costs precision (a wider parameter),
     never correctness. This parameter is documented as inference-dependent. When it is wider than
     the other branch's, the two branches return different concrete types and a comprehension over
     them widens again (SUM-07). That is the documented price.
   - ExplicitImports gets an ignore entry for `Base.promote_op`.
   - **Amendment (2026-10-20; the user's answer to the phase-2 ★ decision 0, option (a), relayed
     by the lead to the lane; the lead confirms it before merge): `LazyList` is the
     documented exception to "never correctness".** A lazily mapped `LazyList`
     (`map`/`chain`/`ap`) fixes its element type from `promote_op` at `map` time and stores
     values computed later, when cells are forced. If a method is added between `map` and
     forcing, and it changes the function's return type, forcing can throw (for example
     `g(x) = 1; l = map(g, lazylist(1:3)); @eval g(x) = 1.5; collect(l)` gives an
     `InexactError`). The other types store eagerly computed values and keep the rule. The
     behaviour is documented in `LazyList`'s docstring. Rejected alternative: element type `Any`
     for lazily mapped lists, which loses type stability on iteration. Found by the phase-2
     reviewer (SHOULD-FIX-1); spec `docs/superpowers/specs/2026-10-20-phase2-datatypes-design.md`
     §6.
5. **Equality, `hash` and `show`** are defined per type over the tag and the **active** slots,
   with `isequal`/`==` recursing into the payload (`some([1]) == some([1])`). `show` prints
   constructor syntax.
6. **Validation** accumulates errors in a fresh `Vector{E}`. It never mutates an input's
   vector. A caller-supplied semigroup is used through ChuiCore's semigroup operation (stand-in
   `Upstream.<op>`, ADR-0004) as a method on `Validation`, never on `Vector` (no piracy). ChuiCore's
   stable `combine(agg, a, b)` (CC-004) is the aggregation protocol, not this. Superseded in part:
   per ChuiCore ADR-0001 the semigroup operation is that same `combine(m, a, b)` on an instance value.
7. **`LazyList{T}`** is a memoised lazy cons for laziness (infinite lists). It is not a bulk path;
   bulk lazy data uses streams (ADR-0003). Forcing a cell is **not thread-safe** in v0.1, and this
   is documented.
8. **`Reader`, `Writer` and `State` are not settled here.** A phase-3 ADR picks their encoding
   from measurements, under three constraints:
   - no public type parameter derived from inference, and no assertion against an inferred type;
   - stack safety for deep binds;
   - laws compared by running both sides on sample inputs.

   The candidates are closure-specialised structs (SUM-12), an erased callable with a result type
   the user declares, and the effect trampoline (ADR-0002 §1).
9. **The brief's IO type** is a thin constructor (`sync(f)`) of `Effect{E,A}` (ADR-0006 §6). It
   is not an alias, not a separate struct, and not named `IO`.
10. **Typeclass instances** (names follow ChuiCore, ADR-0004):

    | Type | Instances |
    |---|---|
    | `Option` | Functor, Applicative, Monad, Alternative, Foldable, Traversable; Semigroup/Monoid when `T` is a Semigroup |
    | `Either` | Functor, Applicative, Monad, Bifunctor, Foldable, Traversable |
    | `Validation` | Functor, Applicative (accumulating), Bifunctor, Foldable, Traversable. **No Monad** (its `ap` would contradict a monadic `ap`) |
    | `These` | Functor, Bifunctor, Foldable, Traversable; Applicative/Monad when `A` is a Semigroup |
    | `NonEmpty` | Functor, Applicative, Monad, Foldable, Traversable, Semigroup |
    | `LazyList` | Functor, Applicative, Monad, Alternative, Foldable, Monoid |
11. **No ADT dependency.** These are hand-written structs. A `:quality` test checks
    `isconcretetype` and `@inferred` on `map`/`flatmap`/`fold` chains. Benchmarks assert zero
    allocations for `Option{Int}`, `Option{String}`, `Either{String,Int}` and
    `Validation{String,Int}` (valid path) chains.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Bare `Union` values / abstract supertype with variants (MLStyle `@data`) | Not concrete; containers widen (SUM-06, SUM-07); no generic `None` (SUM-05). |
| One `Union` field over all variants (hand-written, SumTypes, Moshi, ErrorTypes) | Boxes pointer payloads: `Option{String}` (`opt2-*`) and `Either{String,Int}` (SUM-08) allocate. Saves 8 bytes for isbits `Option`, which does not pay for that. |
| `Bool` tag + undefined payload field | Not stored inline for non-isbits `T` (SUM-04). |
| ResultTypes.jl (two-slot) as a dependency | Owns `Result` and requires `E <: Exception`; an outside package would carry our core contract. |
| `promote_op`-derived, asserted type parameters for `State` | Throws on correct programs after a later method definition (`polate-*`); not public. |
| Closure-specialised `State{F}` as the final answer | Inference lost at depth 3 (SUM-12); deferred to phase 3, not adopted. |
| `Maybe`/`Result` aliases, `Option{T}()` | Two names per concept, which cannot be removed without a breaking change. |

## Consequences

- `Option{Int}` takes 24 bytes instead of 16, and `Either{String,Int}` takes 32 bytes. That is the
  cost of never allocating. A future isbits-only specialisation may shrink it.
- Users must pass the missing type to `none`, `left`, `invalid`, `this` and `that`.
- Exported lowercase constructors (`both`, `this`) take a binding: on 1.10/1.11, `both = 3` in
  `Main` errors **after `both` has been used** (E-24 behaviour). The ★ asks whether to export them or keep them qualified.
- The `Reader`/`Writer`/`State` decision moves to phase 3.

## Verification

- SUM-01 to SUM-13; `.lanes/evidence/` files `sum-*-{113,110}`, `opt2-{113,110}`,
  `opt2b-{113,110}`, `validalloc-{113,110}`, `polate-{113,110}`, `names-{113,110}` and
  `ctor-names-{113,110}` (all at `db74452`). Scripts are in
  [`docs/research/scripts/`](../research/scripts/) (`sumtypes/`, `encoding/`, `names/`).
- UNVERIFIED:
  - a two-slot `Validation`/`These` (extrapolated from `opt2*`/SUM-08);
  - the cause of SUM-12;
  - phase-3 encodings of `Reader`/`Writer`/`State`.

## Revisit when

- Phase 2 measurements contradict the `opt2*`/SUM-08 results for any type.
- Julia stores mixed pointer/isbits unions inline (re-check each minor release).
- ChuiCore's typeclass or laziness ADR changes the instance table or `LazyList`.
