# ADR-0005: Runtime dependencies are ChuiCore and ScopedValues.jl only

- **Status:** Accepted (2026-10-20, user at the ChuiTypes phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint (via the lead)
- **Scope:** ChuiTypes.jl

## Context

Every dependency needs an ADR (ECOSYSTEM §1.4), and every `[deps]`/`[weakdeps]` entry needs a
finite `[compat]` bound (root ADR-0004 rule 3; "root" = the coordinator's `adr/`). `Project.toml` currently has no `[deps]`.
ADRs 0001–0004 of this repo create these needs:

- **ChuiCore**, the hard upstream edge (root ADR-0002 §1). It is unreleased, and it may only
  be taken as a registered `0.0.x` snapshot (root ADR-0004 rule 2).
- **The effect environment and the cancellation token need scoped values** (ADR-0002 §4, §7).
  `Base.ScopedValues` exists from 1.11, and the floor is 1.10 (root ADR-0006; E-25).
  ScopedValues.jl 1.6.2 re-exports Base's types on 1.11+:
  `ScopedValues.ScopedValue === Base.ScopedValues.ScopedValue` holds on 1.13.2 (EFF-10). On both
  1.10.12 and 1.13.2, scoped values reach `@spawn`/`@async`/`Channel`/`Timer` children (EFF-09). Its registry entry gives
  `julia = "1.8.0 - 1"`, deps HashArrayMappedTries `0.2` (which has no deps of its own) and the
  `Logging` stdlib. It does not export `Scope` (checked on 1.13.2; line 3 of the package's ScopedValues.jl source file
  exports `ScopedValue, with, @with, ScopedThunk`).
- **Candidates the research rejected:**
  - SumTypes.jl, Moshi.jl, LightSumTypes.jl, MLStyle.jl, ErrorTypes.jl, ResultTypes.jl
    (SUM-04 to SUM-08, §2 of `sum-types.md`);
  - CancellationTokens.jl and ConcurrentUtilities.jl (EFF-14);
  - Rocket.jl (STR-09) and Transducers.jl (42 packages, STR-11);
  - DataStructures.jl, for the virtual clock's queue (STR-19 used a sorted `Vector`).
- **Allowed without a per-package ADR** (root ADR-0006 rule 4): Compat.jl, for `@compat public`.

## Decision

1. **`[deps]` must be exactly:**
   - **ScopedValues** with `ScopedValues = "1.6"`, from phase 3 (when the runtime lands). Code
     must use `ScopedValues.ScopedValue`/`with`, which is Base's type on 1.11+, and must not
     branch on `VERSION` for it.
   - **ChuiCore**, added only in the switch-over commit for its first registered snapshot (this repo's ADR-0004
     §3), with the exact snapshot as compat (`ChuiCore = "0.0.1"`).
   - **Compat** (`"4.10"`, root ADR-0006 rule 4), added the first time a name needs `@compat public`.
2. **No other runtime dependency.** Each of the following needs its own new ADR:
   - an ADT/pattern-matching library;
   - a cancellation or concurrency library;
   - a reactive library;
   - DataStructures;
   - Transducers.
   An optional bridge (for example to Rocket.jl) must be a package extension (`[weakdeps]` +
   `ext/`) with its own ADR.
3. **Test, benchmark and quality environments** keep the ecosystem's choices:
   - TestItemRunner (root ADR-0007);
   - Supposition `0.3`, test-only (root ADR-0007 §2), always used as `@check record=false` plus
     `@test` (this repo's ADR-0004 §5). Whether its default example database writes files during
     tests is UNVERIFIED: phase 2 checks it and sets `db` explicitly;
   - BenchmarkTools with a `SUITE` for AirspeedVelocity (root ADR-0011);
   - Aqua and ExplicitImports (the scaffold);
   - JET in its own environment.

   Every one of these environments carries finite `[compat]` bounds (root ADR-0004 rule 3).

   **ReTestItems** for the cancellation stress tests is decided by a phase-3 ADR, not here.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| `Base.ScopedValues` only, with a `VERSION` branch that falls back to a task-local `Dict` on 1.10 | Task-local storage is not inherited by child tasks: `task_local_storage(:k, 1); fetch(Threads.@spawn get(task_local_storage(), :k, :absent))` gives `:absent` on 1.13.2 and 1.10.12 (run by this lane). The token and environment must reach children (ADR-0002 §4), and a fallback would be a second code path to test. |
| Raise ChuiTypes' floor to 1.11 to drop ScopedValues.jl | A downstream may not have a lower floor than its upstreams, so ChuiFrames would have to move to 1.11 as well. That overrides the user's L0 decision of `julia = "1.10"` and drops the LTS CI job (root ADR-0006). |
| An ADT library (SumTypes/Moshi/LightSumTypes/MLStyle) | Same layout as a hand-written wrapped union, and they allocate on mixed `Either` (SUM-08). |
| CancellationTokens.jl / ConcurrentUtilities.jl | Not scoped, and no bridge to Base 1.14's tokens (EFF-02, EFF-14); ConcurrentUtilities' timeout leaves the work running (EFF-14). |
| Rocket.jl as the stream base | Push-only with an unbounded default (STR-09; ADR-0003). |
| Transducers.jl | 42-package closure (STR-11). ChuiCore owns the substrate (root ADR-0002 §4). |
| DataStructures.jl for the clock queue | A sorted vector or a ~40-line binary heap is enough (STR-19). |

## Consequences

- The runtime dependency closure is ScopedValues, HashArrayMappedTries and Logging (a stdlib),
  plus ChuiCore later. Load time and TTFX budgets are measured in phase 5.
- Every phase-2 code path must avoid scoped values, so phase 2 stays dependency-free.
- `test/contracts/upstreams.toml` gains ChuiCore's URL only at the switch-over.

## Verification

- ScopedValues facts: EFF-09 and EFF-10 in
  [`docs/research/effect-runtimes.md`](../research/effect-runtimes.md). Registry `Deps.toml` and
  `Compat.toml` for ScopedValues and HashArrayMappedTries were read from
  `~/.julia/registries/General.tar.gz` on 2026-10-20 (`[1.6 - 1] Logging = "1"`,
  `[1.1 - 1] HashArrayMappedTries = "0.2"`; HashArrayMappedTries has no `Deps.toml`).
- The rejected packages are cited above. E-25 (coordinator `research/ecosystem-verification.md`)
  covers Base 1.11 ScopedValues.
- Task-local storage is not inherited: the one-liner in the first alternatives row, run on 1.13.2
  and 1.10.12 (`parent=1 child=absent` on both).
- UNVERIFIED: Supposition's default database behaviour (Decision §3), plus the cited notes'
  own UNVERIFIED lists.

## Revisit when

- The ecosystem raises its Julia floor to ≥ 1.11 (then drop ScopedValues.jl).
- ChuiCore registers a snapshot (add it).
- Phase 3 decides ReTestItems, or phase 4 wants a Rocket.jl bridge.
