- Phase 4 (futures and streams), per ADR-0003, ADR-0006 and the new ADR-0008 (Proposed). Spec
  `docs/superpowers/specs/2026-10-20-phase4-streams-design.md`; all names are proposals for the
  phase-4 ★.
- `Queue{T}(capacity)`, `offer`, `receive`, `close` (public `QueueClosed`): the runtime's bounded
  queue; every wait ends on the caller's own cancellation, and wake-ups are broadcasts.
- `Stream{T}`: cold, pull-based, chunked (about 1024 elements), advisory `T` (`eltype`), errors
  as values. Sources `fromiter`, `fromeffect`, `emptystream`, `failstream`, `interval`, `timer`,
  `bracketstream` (a release that runs exactly once).
- Fused element operators (one transducer pipeline per stream, state carried across chunks):
  `map`, `filter`, `scan`, `Iterators.take`/`drop`/`takewhile`, `buffer`, `window`. Chunks widen,
  never convert. Measured cost (not yet iterator-level, a phase-5 target): about 3.8 ns per
  element for a fused map/filter collect (about 5.5× Base), `runfold` about 43× `foldl`, about
  24 allocations per 1024-element chunk (ADR-0003 "Measured 2026-10-20").
- Combinators: `concat`, `concatmap`, `merge`, `prefetch`, `mergemap` (`maxconcurrent`),
  `switchmap` (generation tags), `catchfail`, `retry(s, schedule)`; producer fibers in the run's
  scope, closed with upstream leases.
- Time operators on the runtime clock (virtual time under `runtest`): `debounce`, `throttle`,
  `buffertime`, `windowtime`; ties decided by time.
- Hot sources: `Subject{T}(; capacity, overflow)` with `publish`, `subscribe`, `close`; per-element
  overflow policies `:block`, `:dropnewest`, `:dropoldest`, `:latest`.
- Running: `runcollect`, `runfold`, `runforeach`, `runchunks` (a bounded snapshot, ADR-0008),
  `withbatches`.
- Adapters (ADR-0006 §5): `fromchannel` (hot, single-consumer; a cancelled wait takes nothing),
  `tochannel` (closing the channel cancels the producing fiber).
- Futures: `collectpar(effs; maxconcurrent)` (Fluture's `parallel`); the Fluture and Folktale
  correspondence is in `test/test_futures.jl`.
- Marble testing: public `ChuiTypes.marbles` and `ChuiTypes.marbletrace` on virtual time.
- `Upstream` gains transducer stand-ins mirroring ChuiCore's protocol (`Map`, `Filter`, `Take`,
  `TakeWhile`, `Scan`, `Partition`, `Composed`, `Reduced`, `asrf`, `start`/`next`/`complete`).
- Tests: unit and marble tests for every operator in the brief's list; property tests with
  planted violations (fusion vs the list model, cancellation leaves no live fiber and releases
  once, marble round trip, queue exactly-once); Stream law tests; `:slow` stress tests (real-time
  section in a child process). ADR-0008 (Proposed): the bounded stream → ChuiFrames Source path.
