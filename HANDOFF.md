# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase5`, the phase-5 integration branch, cut from `main` at `08e9468`
  (phases 1–4 and factory 0.2.7 merged). **Not merged**: the lead merges it into `main` after
  the final review.
- **Remote:** nothing pushed.
- **Phase:** **phase 5 (performance: allocations and TTFX) is implemented** on the branch.
  - Spec: `docs/superpowers/specs/2026-10-26-phase5-performance-design.md`. Plan:
    `docs/superpowers/plans/2026-10-26-phase5-performance.md`. Critic: FINAL ACCEPT.
  - Lane `p5-perf`, merged at `9bbf10c`, covered the stream hot path:
    - an indexed `fromiter` source for Vector, ranges and Vector views (`src/stream/sources.jl`);
    - a typed generic-source state;
    - a pre-sized, indexed fused sink;
    - no per-chunk boxing;
    - a typed `runfold` accumulator;
    - a LazyList barrier;
    - an interpreter `Core.Box` removed.
    - New tests: `test/test_perf.jl` (allocation budgets) and `test/test_stream_fastpath.jl`.
    - ADR-0003 got a dated note: "fused operators cost what an iterator does" is still NOT met
      (about 3.8× Base collect, 22× Base foldl). The lead accepted this for phase 5.
  - Lane `p5-ttfx`, merged at `c67c87d`, added the precompile workload:
    - a dependency-free workload, run only while the image is generated (`src/precompile.jl`);
    - `benchmark/ttfx.jl`;
    - `test/test_precompile.jl`.
    - TTFX workload total: 1.77 → 0.28 s on 1.13.2, 1.30 → 0.18 s on 1.10.12 (loaded machine).
  - **ADR-0009** (Proposed) records the performance budgets, enforced by tests. It cites
    `test/test_perf.jl` and `test/test_precompile.jl`, and also records the losses, the JET
    triage and the follow-ups.
- **Dependencies:** unchanged (`Compat`, `ScopedValues`). PrecompileTools was rejected
  (ADR-0005 §2; ADR-0009).
- **Evidence:** `.lanes/evidence/` (gitignored) of each worktree. The integration files are
  `tests-9bbf10c.txt` (17270 pass, 1.13) and `tests-lts-9bbf10c.txt` (17255 pass, 1.10). The lane
  files are copied into the phase5 worktree.

## Open lanes

| Lane | Branch | Status |
|---|---|---|
| `phase5` | `feat/phase5` | integration: ADR-0009 Proposed; integrated TTFX re-measure PENDING (quiet window, scheduled by the lead); final review next |
| `p5-perf` | `feat/p5-perf` | merged into `feat/phase5`; reviewer FINAL APPROVE (twice); worktree can be removed |
| `p5-ttfx` | `feat/p5-ttfx` | merged into `feat/phase5`; reviewer FINAL APPROVE; worktree can be removed |

## Decisions taken (the lead, 2026-10-26)

1. TTFX uses a dependency-free workload guarded by `jl_generating_output`, not PrecompileTools,
   with no ADR-0005 change.
2. The S1/S2 time-target misses are accepted for phase 5. ADR-0009 records the after-numbers as
   the budget, and ADR-0003 gets a dated "NOT met" note; its decision text is unchanged.
3. `merge` over Vector sources about 1.6× slower is a known loss, after one bounded fix attempt.
   - Cause: fast producers park and wake across threads on a full bounded queue.
   - Rejected fix: waking producers only at half-drain, because it breaks `offer`'s documented
     contract.
   - A benchmark row `merge 4x2.5e5 Vector` covers it.
4. The integrated TTFX figures come from a quiet window (1-min load < 2) that the lead schedules.

## Follow-ups (ADR-0009 lists them)

- Fold `runfold` into the fused pipeline, so no output chunk is built. This is the remaining
  S1/S2 gap.
- The `merge` over Vector park/wake loss.
- Fix the `_interpret` JET `report_package` reports, then drop the workload's `Ref{Any}(run)`
  indirection (about 0.03 s).
- `scan` cannot change its accumulator type: `scan(+, 0, fromiter([1, 2.5, 3]))` fails with a
  convert error. This predates phase 5.
- An emitted chunk can be up to 4× oversized, because `resize!` keeps the capacity.
- `test/laws/test_planted.jl:61` is flaky on the LTS. It is probabilistic by design
  (`test/laws/kits.jl:56-58`).
- An ADR-0003 nit: "50–200 range parks" should say about 40–200.
- From phase 4, still open: a non-leased pump's close cause is lost from `suppressed` (in
  `src/stream/concurrent.jl`).

## Phase 5 item still BLOCKED

- **Switch `Upstream` to ChuiCore 0.0.1** (ADR-0004 §3, and the §2 note of 2026-10-20). It waits
  for the lead to say ChuiCore 0.0.1 is registered.

## Checks NOT run, and why

- The integrated TTFX medians: deferred to the lead's quiet window. The `:slow` ceiling item did
  pass on the integrated head under load: 0.33 s on 1.13 and 0.19 s on 1.10, against ceilings of
  1.0 and 0.75 s.
- No time measurement on a quiet machine: all phase-5 time figures are labelled with their load
  average (1-min 3.2–12).
- Julia 1.14 (alpha), 1.12, and `pre`: no local binaries. The `test_perf.jl` rows cover 1.13 and
  1.10; any other version gets a loose ceiling.
- `ci.jl contracts`: it skips, because there is no ChuiCore URL yet.
- GitHub workflows, including the coverage job, where `test_perf.jl` and the `:slow` TTFX item
  skip themselves: no remote.

## Next action

1. The lead's quiet window: run the one-shot TTFX command, then fill ADR-0009's PENDING rows.
2. The final reviewer on `main...feat/phase5`.
3. The lead merges into `main`.
4. Then phase 6 (docs), or item 1 once ChuiCore 0.0.1 is registered.
