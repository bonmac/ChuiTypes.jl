# Phase 3 plan: Reader/Writer/State, the effect runtime and its adapters

- **Lane:** `phase3-effects`, branch `feat/phase3-effects`, from `main` at `dc1882c`.
- **Tier:** T2 (public API; new dependency `ScopedValues = "1.6"`, ADR-0005). Spec:
  `docs/superpowers/specs/2026-10-20-phase3-effects-design.md`. New ADR: ADR-0007 (Proposed).
- **Out of scope:** streams, `Queue`, channel adapters, futures (phase 4).

## Tasks (TDD: each test file is written and seen failing before its source file)

1. **ADR-0007** from measurements (`docs/research/scripts/encoding/rws_encodings.jl`, evidence
   `rws-*`, `rwsdeep-*`), critiqued by a critic agent; fixes applied.
2. **Reader/Writer/State** (sub-lane `rws`, scratch clone): `src/reader.jl`, `src/writer.jl`,
   `src/state.jl`, unit tests, law tests through the kits with a running `eq`.
3. **Effect core** (`src/effect/`): `types.jl` (nodes, `Effect`, `Cause`, `Exit`, exceptions),
   `context.jl` (cancel states, waiters, the fiber context, the `ScopedValue` bridge, counters),
   `interpreter.jl` (the explicit-stack loop, unwinding, masking), `api.jl` (constructors,
   `map`/`andthen`, errors, environment, `run`/`runexit`). Tests: `test/test_effect.jl`, laws in
   `test/laws/test_laws_effect.jl`.
4. **Concurrency** (`src/effect/fiber.jl`): `Fiber`, `fork`, `start`, `scope`, supervision,
   `interrupt!`, `await`, `fromexit`, `fetch`/`wait`; `bracket`, `acquirerelease`, `ensuring`.
5. **Clock and test mode** (`src/effect/clock.jl`): `RealClock`, `VirtualClock`, `delay`,
   `clocktime`, `advance!`, `runtest`. Then `race`, `racefirst`, `zippar`, `timeout`,
   `timeoutfail` (`src/effect/combinators.jl`), `retry` and schedules (`src/effect/schedule.jl`).
6. **Adapters** (`src/effect/adapters.jl`): `async`, `fromtask` (Task and Function), `totask`.
7. **Properties and stress** (`test/test_effect_props.jl`, `test/test_effect_stress.jl`): finalizers
   exactly once and LIFO under cancellation at a random step; round trips; planted violations
   (`test/laws/test_planted.jl`, run on 1.10); leak stress (`:slow`) on `livefibers()`.
8. Docs: docstrings, `changelog.d/phase3-effects.md`, `HANDOFF.md`, ADR index.

## Gates

`ci.jl test` on 1.13.2 and `julia +lts`, `test -- all`, `quality`, `jet`, `format`, `guards`,
`dod.jl --base main` and `--base dc1882c`, `scripts/lane audit phase3-effects`; a read-only
reviewer on the full diff, iterated to a FINAL ACCEPT.
