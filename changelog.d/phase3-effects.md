- Phase 3 (Reader/Writer/State, the effect runtime and its adapters), per ADR-0002, ADR-0006,
  ecosystem ADR-0013 and the new ADR-0007 (Proposed). Spec
  `docs/superpowers/specs/2026-10-20-phase3-effects-design.md`; all names are proposals for the
  phase-3 ★.
- `Reader{R}`, `Writer{W}`, `State{S}` (ADR-0007): erased node trees with one declared parameter,
  run by an explicit-stack interpreter (stack-safe at 10^6 binds). `ask`, `asks`, `withreader`,
  `runreader`; `tell`, `listening`, `censor`, `runwriter` (a caller-supplied monoid);
  `getstate`, `putstate`, `modifystate`, `runstate`; tags `ReaderTag`/`WriterTag`/`StateTag`.
- The effect runtime (ADR-0002): `Effect{E,A}` (advisory parameters), `succeed`, `fail`, `die`,
  `sync`, `attempt`, `defer`, `andthen` (the public bind, also for Reader/Writer/State), `map`;
  `run` (a `Base.run` method) and `runexit`; outcomes `Exit`/`Cause` (`Success`, `Failure`,
  `Fail`, `Die`, `Interrupted`, public) and the exceptions `EffectFailed`, `Cancelled`,
  `MissingService`; `catchfail`, `catchcause`, `mapfail`; `provide`/`service`;
  cooperative, level-triggered cancellation (`interrupt!`, `checkcancel`, `uninterruptible`,
  `interruptiblemask`) bridged through one `ScopedValue` per `sync`; `Fiber`, `fork`, `start`,
  `await`, `fromexit`, structured `scope`s with supervision; `bracket`, `acquirerelease`,
  `ensuring` (LIFO, masked); `race`, `racefirst`, `zippar`, `timeout`, `timeoutfail`; the clock
  service (`delay`, `clocktime`, `RealClock`) and test mode (`VirtualClock`, `advance!`,
  `runtest`); `retry` with `recurs`/`spaced`/`exponential` (PROVISIONAL); counters `livefibers`,
  `orphans`.
- Adapters (ADR-0006, ecosystem ADR-0013): `async(register; grace)`, `fromtask(::Task;
  canceller)`, `fromtask(::Function)`, `totask`. `fetch` on a `Fiber` throws the original
  exception; a `totask` task's `TaskFailedException` carries it as `task.exception`.
- New runtime dependency: ScopedValues `1.6` (ADR-0005).
- Tests: law tests for Reader, Writer, State and Effect; property tests (finalizers exactly once
  and LIFO under cancellation at a random step and at a random real time, scopes leave no live
  fiber, the Task round trip) each with a planted violation that runs on 1.10; leak stress tests
  (`:slow`); virtual-time determinism tests. Benchmarks for the two interpreters.
- Fix: `_LazyCell` has an inner constructor (Aqua's unbound-type-parameter check failed on 1.10).
