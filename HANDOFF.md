# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase4-streams`, cut from `main` at `bd8bcc0` (phases 1–3 merged). It is
  **not merged**: it waits for the lead's review and merge.
- **Remote:** none pushed from this lane.
- **Phase:** **phase 4 (futures and streams) is implemented** on the branch.
  - Spec: `docs/superpowers/specs/2026-10-20-phase4-streams-design.md` (critic: ACCEPT WITH
    FIXES; fixes applied). ADR-0008 (**Proposed**): a bounded stream becomes a ChuiFrames Source
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
| `phase4-streams` | types-p4 (lead-dispatched) | `src/**`, `ext/**`, `test/**`, `Project.toml`, `docs/**`, `benchmark/**`, `HANDOFF.md`, `changelog.d/phase4-streams.md`, `.gitignore`, `JuliaTestItems.toml` | implemented; review round 1 REJECT (B1, B2, S3–S5, N6–N8), all fixed with RED→GREEN tests; re-review pending | SendMessage to the lead, 2026-10-20 |

## Decisions waiting (for the lead / the user at the phase-4 ★)

1. **ADR-0008** (bounded stream → Source by snapshot): Proposed; accept or amend.
2. **Names** (spec §1): every new export and public name.
3. **ADR-0003 departures** (spec §6, §7): `interval`/`timer` are cold (ADR-0003 §5 lists timers
   as hot); `Subject` waits on the runtime's `_park!` directly instead of `async` (needs an
   ADR-0003 §5 amendment).
4. **ADR-0004 and the transducer stand-ins** (spec §14): a minimal re-implementation of
   ChuiCore's protocol in `Upstream`; within ADR-0004 §2 or not.
5. **R10** stays open: ADR-0008 answers its stream questions; export tiers, CT IDs and the
   `chui-types.md` "Stream as a Source" amendment (T3) are draft requests in the lane report.

## Phase 5 (performance), first items

1. **ADR-0003's "fused operators cost what an iterator does" is NOT met** (ADR-0003 "Measured
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

The lead's review and merge, then the phase-4 ★. Then phase 5 (performance, item 1 above).
