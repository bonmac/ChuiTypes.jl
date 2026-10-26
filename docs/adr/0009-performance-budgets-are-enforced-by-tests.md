# ADR-0009: Performance budgets are enforced by tests, with every loss published

- **Status:** Proposed (2026-10-26, phase 5)
- **Date:** 2026-10-26
- **Deciders:** the lead (dep-free workload, accepted losses); the user at the phase-5 ★
- **Scope:** ChuiTypes.jl

## Context

Phase 5 (spec `docs/superpowers/specs/2026-10-26-phase5-performance-design.md`) cut allocations and
TTFX; a number holds only if a check fails when it drifts. Evidence files live in the lane worktree
their prefix names (`.worktrees/<lane>/.lanes/evidence/`), copied into `feat/phase5`'s gitignored
`.lanes/evidence/`. Machine for every row: Apple M3 Pro, 1 thread, Julia 1.13.2 and 1.10.12.

## Decision

1. **Allocation budgets** must live in `test/test_perf.jl` (`:unit`), one row per Julia
   major.minor, the one source this ADR cites; a version with no row gets a loose 2× ceiling.
2. **TTFX ceilings** must live in `test/test_precompile.jl` (`:slow`): 1.0 s on 1.13, 0.75 s on
   1.10 (0.6× the pre-workload baseline). They catch a broken workload; the target is not asserted.
3. **Time rows** are `benchmark/benchmarks.jl` medians; `ratchets.toml` `bench.time_tolerance` 0.10, warn-only (coordinator ADR-0011).
4. **The precompile workload must stay dependency-free** (lead decision 2026-10-26): `src/precompile.jl`
   runs only under `ccall(:jl_generating_output, Cint, ()) == 1`, public API only. PrecompileTools
   is rejected: a new direct dependency against ADR-0005 §2. Workload effects must be `run` through
   `Ref{Any}(run)`, because a concretely inferred `_interpret` gives JET's `report_package` 6 false
   positives from erased node fields (ADR-0007). It costs about 0.03 s on 1.13 (median total 0.2535
   s at 7883316, 0.2834 s at 4f44bfd; `p5-ttfx-after-7883316.txt`, `p5-ttfx-after-4f44bfd.txt`).
5. **Every loss must be published** here and in the changelog, beside the wins.

### Budget table

Allocations per 1024-element source chunk, or per bind (effect, state). Budgets are copied from
`test/test_perf.jl` `BUDGETS`. Mode A, the enforced one: `julia scripts/ci.jl test` (`Pkg.test`,
`--check-bounds=yes`, 2^17 elements; `p5-perf-calib-a53e094.txt`, `p5-perf-calib-lts-a53e094.txt`;
load not recorded, counts do not depend on it). Mode B, information only: a plain process (10^6
elements; `p5-perf-after-3c4e32e.txt`, `p5-perf-after-allocs-lts-3c4e32e.txt`, 1-min load 5.0–5.3).

| case | 1.13 budget | 1.13 A | 1.13 B | 1.10 budget | 1.10 A | 1.10 B |
|---|---|---|---|---|---|---|
| S1 fused map/filter collect | 7.5 | 6.88 | 6.12 | 4.5 | 4.00 | 3.13 |
| S2 fused map runfold | 7.5 | 6.83 | 6.11 | 5.0 | 4.02 | 3.13 |
| S4 source runfold Vector | 4.5 | 3.72 | 3.09 | 3.5 | 2.95 | 2.12 |
| S4range source runfold 1:n | 4.5 | 3.70 | 3.09 | 3.5 | 2.93 | 2.12 |
| generic iterator source | 5.5 | 4.72 | 4.09 | 4.5 | 3.95 | 3.12 |
| effect, per bind | 2.5 | 1.95 | 1.95 | 2.5 | 1.96 | 1.96 |
| state, per bind | 4.5 | 3.90 | 3.90 | 4.5 | 3.90 | 3.90 |

TTFX rows: the workload total from `benchmark/ttfx.jl`, median of 7 fresh processes.

| Julia | before | p5-ttfx lane | integrated `feat/phase5` | ceiling | compilecache before → after |
|---|---|---|---|---|---|
| 1.13.2 | 1.769 s | 0.283 s | PENDING: quiet-window re-measure (1-min load < 2), scheduled by the lead | 1.0 s | 0.651 → 1.983 s |
| 1.10.12 | 1.296 s | 0.178 s | PENDING (same) | 0.75 s | 0.711 → 2.007 s |

Before: `p5-ttfx-before-339c806.txt` (1-min load 4.9–5.6, loaded); lane: `p5-ttfx-after-4f44bfd.txt`
(1-min load 3.9–4.3, loaded). Integrated: kind `p5-ttfx-integrated` (p5-perf changed what it compiles).

Time rows, 1.13.2, ns per element or bind, median / min: before `p5-perf-before-suite-4ec7894.txt`
(1-min load 5.1–6.3), after `p5-perf-after-suite-673a0be.txt` (2.8–3.5).

| row | before | after |
|---|---|---|
| fused map runfold 10^6 | 5.021 / 3.824 | 1.859 / 1.644 |
| fused map/filter collect 10^6 | 3.74 / 2.081 | 2.027 / 1.793 |
| fromiter Vector runfold 10^6 | (new row) | 0.325 / 0.289 |
| merge 4x2.5e5 (range sources) | 2.029 / 1.022 | 0.938 / 0.756 |
| Effect 10^4 binds | 63.325 / 60.242 | 42.112 / 40.096 |
| State 10^4 binds | 40.146 / 37.262 | 42.512 / 38.604 |

### Losses published

- **compilecache costs about +1.3 s** per version (TTFX table; `p5-ttfx-precompile-4f44bfd.txt`).
- **ADR-0003's fused-operator claim stays NOT met**, accepted by the lead for phase 5: S1 about 3.8× Base collect (1.974 vs 0.518), S2 about 22× Base `foldl` (1.676 vs 0.076; `p5-perf-after-quiet-673a0be.txt`, load 3.2–3.9).
- **`merge` over `Vector` sources got slower** (row `merge 4x2.5e5 Vector`): median 2.229 → 3.635
  ns per element, about 1.6× (min 1.293 → 1.217; 1-min load 9.3–12.9; `p5-perf-merge-5e13f87.txt`).
  Fast producers fill the bounded queue, then park and wake across threads 743–806 times per run,
  against 37–194 for range pumps (`p5-perf-merge-cause-673a0be.txt`). A half-drain wake cut that
  to 284–338 but was rejected: it changes `offer`'s contract. State binds did not improve.

### JET triage (`report_opt`, per-chunk path, 28 reports, `p5-perf-jet-after-3c4e32e.txt`; lines at 3c4e32e)

- `src/stream/fused.jl` (unchanged since) line 76: the dynamic `_spull!` on the erased upstream
  `p.up`, once per chunk; line 86: `_fusedchunk!`, the one function barrier per chunk.
- Error and widening paths: `src/stream/core.jl` 57 (now 58; `_classify` in `_spull!`'s catch),
  165 (now 166; `_widenpush!`), 374/376 (now 375/377; `_foldstep!`, `runfold`'s `Ref{Any}`
  state), `src/upstream.jl` 201 (`_rewrap`, the `Reduced` branch of `scan`).
- `src/lazylist.jl` lines 88, 92 (`p5-perf-d6-lazylist-5e13f87.txt`): the erased thunk call, the barrier.
- `_interpret`'s reports: expected under ADR-0007 (erased node fields); see Decision 4.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| PrecompileTools `@compile_workload` | It would be a new direct dependency (ADR-0005 §2). On a prototype at 08e9468 it measured no faster than the dependency-free workload: workload-total medians of 0.315 s vs 0.269 s on 1.13.2, and 0.185 s vs 0.150 s on 1.10.12. N = 7, 1-min load 5.4, loaded (`ttfx-p5-08e9468.txt`) |
| Asserting the TTFX target, or failing CI on time rows | Too load-sensitive on a shared machine (medians above move up to 2× under load); coordinator ADR-0011 |
| One allocation row for all versions | 1.10 allocates about one fewer per 1024-element Vector (`test/test_perf.jl`) |
| Half-drain putter wake for `merge` | It changes `offer`'s contract (Losses) |

## Consequences

- Extra allocations fail `ci.jl test`, slow TTFX fails `:slow`, time only warns; new minors need rows.

## Follow-ups

1. Fold `runfold` into the fused pipeline, so it builds no output chunk.
2. Fix the `merge`-over-`Vector` park/wake loss without changing `offer`.
3. Fix the `_interpret` JET reports, then drop the workload's `Ref{Any}`.
4. `scan` cannot change its accumulator type: `scan(+, 0, fromiter([1, 2.5, 3]))` fails on `convert` (predates phase 5).
5. An emitted chunk can be up to 4× oversized: `resize!` keeps capacity (`_emit!`, `core.jl` ~188).
6. `test/laws/test_planted.jl:61` is flaky on the LTS, probabilistic by design (`test/laws/kits.jl:56-58`).
7. ADR-0003 nit: "50–200 range parks" should read about 40–200 (evidence: 37–194).

## Verification

At ff93788, which is the tree of the integration head after the final-review fix for huge
ranges, `ci.jl test -- all` passes on both versions, with clean trees: 17283 pass on 1.13.2
(`tests-ff93788.txt`) and 17268 pass on 1.10.12 (`tests-lts-ff93788.txt`). Those runs include
the budget item, with the same mode-A counts, and the `:slow` TTFX ceiling. The ceiling item's
minimum of 3 was 0.2949 s on 1.13.2 and 0.1821 s on 1.10.12, on a loaded machine (no load
figure was recorded). PENDING: integrated TTFX medians (quiet-window re-measure).

## Revisit when

- `Upstream` switches to ChuiCore 0.0.1 (phase-5 item 1, still blocked), the Julia floor rises past 1.10, a new minor ships, or a follow-up lands.
