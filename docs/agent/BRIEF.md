<!-- package brief: coordinator commit 16b9e6a, prompts/20-chui-types.md, copied 2026-10-19 -->

# Package brief: ChuiTypes.jl (data types, effects, streams)

The lead session hands this brief to the agents working on **ChuiTypes.jl**.
- **Upstream:** it depends on **ChuiCore.jl**, through *released* versions only.
- **Downstream:** ChuiFrames and the future packages depend on it.

Lanes for this package edit and commit only in `<root>/ChuiTypes.jl`.

**Read first:**
- `docs/agent/ECOSYSTEM.md`.
- `<root>/contracts/chui-core.md`: what you may use from ChuiCore. Carry contract tests for it in `test/contracts/`.
- `<root>/contracts/chui-types.md`: what you promise downstream.
- `HANDOFF.md`.

## Scope

- **Data types:** `Option`/`Maybe`, `Either`/`Result`, `Validation` (accumulates errors), `These`, `NonEmpty`, `LazyList`, `Reader`, `Writer`, `State`, `IO`.
  - Each implements the ChuiCore traits that apply to it, and passes ChuiCore's exported law-test kits.
- **A ZIO-style effect:**
  - environment + error + success channels;
  - resource safety (`bracket`/`Scope`);
  - retries and schedules, timeouts;
  - structured concurrency on Julia `Task`s, and cancellation that propagates.
  - Also, adapters to and from plain `Task`, `Channel` and exceptions.
- **Futures:** Fluture-style lazy, cancellable futures; Folktale/Monet-style `Task`.
- **Reactive streams (RxJS / Monix / fs2 / ZIO Streams):**
  - cold and hot observables;
  - operators: map, filter, scan, merge, concat, switchMap, mergeMap, debounce, throttle, buffer, window, retry;
  - schedulers, including a virtual-time scheduler for testing;
  - backpressure.
  - Streams must be usable as a ChuiFrames **source**: agreed in the root repo through `chui-frames.md`'s `Source` interface.
- **Inspiration:**
  - JavaScript: Ramda, Sanctuary, Fluture, Folktale, Purify, Monet, daggy, Underscore/Lodash (lodash/fp), RxJS;
  - Scala: cats, cats-effect, ZIO, fs2;
  - Haskell `mtl`/`transformers`.

## Independence

- **Before ChuiCore's v0.1 release:** build against the ChuiCore contract by depending on ChuiCore's registered `0.0.x` snapshots from the personal registry (ADR-0004 rule 2).
  - If there is no tag yet, implement the types and their own logic first, and put a thin adapter layer where ChuiCore's traits will plug in.
- **Missing upstream features:** write a cross-repo request in `<root>/requests/` for the lead to schedule. A ChuiTypes lane never edits ChuiCore's code.

## Phases
1. **Research and ADRs:**
   - an encoding of these types that stays type-stable;
   - the effect runtime design (fibers or `Task`s, cancellation semantics);
   - the stream design (push or pull, backpressure).
   - ★ Report to the lead before implementing.
2. **Core data types**, plus laws.
3. **Reader/Writer/State/IO**, and the effect runtime with resource-safety and cancellation tests.
4. **Futures and streams:** marble tests (Rx-style timeline tests) on virtual time; stress tests for leaks and cancellation.
5. **Performance:** allocations and TTFX.
6. **Docs.** Then v0.1.0, after the user confirms; record it in `<root>/releases.md`.

## Done means
- **Laws:** pass for every instance.
- **Effects:** cancellation and resource-safety property tests pass, and stress tests show no leaked tasks.
- **Contracts:** contract tests pass against ChuiCore's latest release.
- **Quality checks:** JET and Aqua are clean.
- **Standalone:** `]test` passes from a fresh clone.
