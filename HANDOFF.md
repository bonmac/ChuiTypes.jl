# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase4-streams`, cut from `main` at `bd8bcc0` (phases 1–3 merged). It is
  **not merged**: it waits for the lead's review and merge.
- **Remote:** none pushed from this lane.
- **Phase:** **phase 4 (futures and streams) is implemented** on the branch.
  - Spec: `docs/superpowers/specs/2026-10-20-phase4-streams-design.md` (critic: ACCEPT WITH
    FIXES; fixes applied). ADR-0008 (**Accepted** at the phase-4 ★): a bounded stream becomes a ChuiFrames Source
    by a snapshot (`runchunks`).
  - `src/stream/`: `queue.jl` (Queue), `core.jl` (Stream, protocol, driver, sources, run
    functions, `withbatches`), `fused.jl` (transducer-fused element operators), `sequential.jl`
    (concat, concatmap, catchfail, retry), `concurrent.jl` (pumps, merge, prefetch, mergemap,
    switchmap), `time.jl` (interval, timer, throttle, debounce, buffertime, windowtime), `hot.jl`
    (Subject), `adapters.jl` (fromchannel, tochannel), `marbles.jl`, `futures.jl` (collectpar).
    `src/upstream.jl` gains transducer stand-ins mirroring ChuiCore's protocol.
  - Tests: `test_queue.jl`, `test_stream.jl`, `test_stream_marbles.jl`, `test_stream_hot.jl`,
    `test_stream_adapters.jl`, `test_stream_source.jl`, `test_futures.jl`,
    `test_stream_props.jl` (properties + planted), `laws/test_laws_stream.jl`,
    `test_stream_stress.jl` (`:slow`). Benchmarks: `benchmark/benchmarks.jl` group `streams`.
- **Dependencies:** unchanged (`Compat`, `ScopedValues`). ChuiCore is still not a dependency.
- **Evidence files:** `.lanes/evidence/` (gitignored); the lane's report lists commands and counts.

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| `phase4-streams` | types-p4 (lead-dispatched) | `src/**`, `ext/**`, `test/**`, `Project.toml`, `docs/**`, `benchmark/**`, `HANDOFF.md`, `changelog.d/phase4-streams.md`, `.gitignore`, `JuliaTestItems.toml` | implemented; review round 1 REJECT (B1, B2, S3–S5, N6–N8), all fixed with RED→GREEN tests; reviewer **FINAL ACCEPT** at `f72bed8`; waiting for the lead's merge | SendMessage to the lead, 2026-10-20 |

Follow-up the reviewer left as a NIT (not fixed on this branch): a non-leased pump's close cause
is kept in a `_PumpCtl` the coordinator discards, so an inner whose input failed **and** whose
close failed loses the close cause from the failure's `suppressed` list, as does a superseded
`switchmap` inner's close failure (`src/stream/concurrent.jl`, `first(_forkpump(...))`).

## Decisions taken (user at the phase-4 ★, 2026-10-20; all as recommended)

1. **ADR-0008** (bounded stream → Source by snapshot): **Accepted**.
2. **Names** (spec §1): accepted as proposed.
3. **ADR-0003 §5 amended** (dated): `interval`/`timer` are cold, a clock per run; `Subject` parks
   directly on the runtime.
4. **ADR-0004 §2 note** (dated): the `Upstream` transducer stand-ins are within the rule for now;
   switching to ChuiCore 0.0.1 is phase-5 item 1.
5. **`bracketstream`'s `Interrupted` exit** under a concurrent stop (a producer still running) is
   confirmed as documented.
6. **R10** stays open (ChuiFrames' Task shim); the lead files the draft requests (export tiers,
   CT IDs, the `chui-types.md` "Stream as a Source" amendment, the reproducer fix) after merging.

## Phase 5, in order

1. **Switch `Upstream` to ChuiCore 0.0.1** (ADR-0004 §3, and the §2 note of 2026-10-20): the
   typeclass and transducer stand-ins become `using ChuiCore: …`, instance methods get typed
   styles (rule N5), contract tests start running.
2. **ADR-0003's "fused operators cost what an iterator does" is NOT met** (ADR-0003 "Measured
   2026-10-20"; `.lanes/evidence/bench-streams-bd8bcc0.txt`, loaded machine): fused map/filter
   collect about 5.5× Base, `runfold` about 43× `foldl`, about 24 allocations / 15 KB per
   1024-element chunk. Suspected causes, **UNVERIFIED** (not profiled): the untyped `runfold`
   accumulator (`Ref{Any}`), the sink's growth without a size hint, per-chunk closures. A
   pre-sized-buffer change was left out of this branch because it was not measured.

## Checks NOT run, and why

- Julia 1.14 (alpha) and 1.12: no runnable binaries locally.
- `ci.jl contracts`: skips (waiting): `test/contracts/upstreams.toml` has no ChuiCore URL.
- GitHub workflows: no remote from this lane.
- Benchmarks: one run on a loaded machine (1.13.2, one thread); not on 1.10, not idle.
- **Stale `origin/main` (the lead's).** `scripts/lane audit` and `dod.jl --base main` may compare
  against `origin/main`; `dod.jl --base bd8bcc0` gives this branch's true diff.

## Next action

The lead's merge (the phase-4 ★ is answered, above). Then phase 5, in the order above: the
ChuiCore 0.0.1 switch-over first, then the stream cost work.
