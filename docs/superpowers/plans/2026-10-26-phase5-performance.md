# Phase 5 plan: performance (allocations and TTFX)

Spec: [`../specs/2026-10-26-phase5-performance-design.md`](../specs/2026-10-26-phase5-performance-design.md).
Integration branch: `feat/phase5` (lane `phase5`, from `main` 08e9468). Both work lanes branch
from `feat/phase5` (`--base feat/phase5`) and merge back into it; the lead merges it into `main`.

## Lanes (disjoint scopes; at most 2 agents open at once)

| Lane | Branch | Owns (exact `--owns` value) |
|---|---|---|
| `p5-perf` | `feat/p5-perf` | `src/stream/*,src/lazylist.jl,src/effect/*,src/state.jl,src/rws.jl,benchmark/benchmarks.jl,benchmark/Project.toml,test/test_perf.jl,test/test_stream*.jl,test/test_lazylist.jl,test/laws/test_laws_stream.jl,docs/adr/0003-*` |
| `p5-ttfx` | `feat/p5-ttfx` | `src/ChuiTypes.jl`, `src/precompile.jl`, `test/test_precompile.jl`, `benchmark/ttfx.jl` (comma-joined in the `--owns` value) |
| `phase5` (integration) | `feat/phase5` | `docs/superpowers/specs/2026-10-26-phase5-*,docs/superpowers/plans/2026-10-26-phase5-*,HANDOFF.md,docs/adr/0009-*,docs/adr/README.md` |

`changelog.d/<lane>.md` is added to each lane's scope by `scripts/lane`. `src/effect/*`,
`src/state.jl`, `src/rws.jl` are in `p5-perf` only for spec D7 (a single dominant per-bind site);
no change there is expected. `p5-ttfx` never edits `src/stream/**`; `p5-perf` never edits
`src/ChuiTypes.jl` (so the `include("precompile.jl")` line has one owner).

## Lane `p5-perf` (implementer)

TDD; each step RED → GREEN → commit (Conventional Commits).
1. Baseline: run `benchmark/benchmarks.jl` groups `streams` and `interpreters` plus the S1/S2/S4
   allocation probe on the lane's base, recorded with `uptime` through
   `julia scripts/evidence.jl p5-perf-before -- …` (1.13 and +lts for allocations).
2. `test/test_perf.jl` (`:unit`): allocation-per-chunk and per-bind assertions, first at the
   **target** values of spec §3 (RED on the base), helper functions in a `@testsnippet`/
   `@testmodule` so `@allocations` runs inside a function.
3. Property test (`test/test_stream_props.jl` or `test_stream.jl`): the indexed fast path equals
   the generic path (elements, chunk lengths, chunk `eltype`, failure) over every input listed in
   spec R4 (offset axes, undef slots, resized vector, state-type-changing iterator included).
4. D1 pre-sized sink → D2 indexed `fromiter` → D3 generic source unboxing → D4 fused barrier →
   D5 runfold (only if measured to help) → D6 LazyList JET sites → D7 Effect/State per-bind
   measurement. Re-measure after each; drop a step that does not measurably help.
5. Set the `test/test_perf.jl` bounds to measured-after + stated headroom (per Julia version),
   GREEN on 1.13.2 and +lts.
6. D9 benchmark rows; D10 `Stream` docstring and ADR-0003 dated bullet citing the evidence.
7. After-measurement `julia scripts/evidence.jl p5-perf-after -- …` with `uptime`; JET
   `report_opt` probe on the per-chunk path recorded as evidence (scratch script under
   `.lanes/`, not committed).
8. Gates (each bounded with `--timeout`): `ci.jl test -- all` on 1.13 and +lts (through
   `scripts/evidence.jl tests -- …`), `ci.jl quality`, `ci.jl jet`, `ci.jl format`,
   `ci.jl guards`; `changelog.d/p5-perf.md`; `scripts/lane audit p5-perf`.

## Lane `p5-ttfx` (benchmarker)

1. `benchmark/ttfx.jl` (spec T4) and a baseline on the lane's base, 1.13.2 and +lts, N = 7, with
   compilecache time and `uptime` (`julia scripts/evidence.jl p5-ttfx-before -- …`).
2. `test/test_precompile.jl`: `:unit` item (RED: `ChuiTypes._workload` undefined) for T2; `:slow`
   item running `benchmark/ttfx.jl` in a fresh process against the T3 budget.
3. `src/precompile.jl` (T1) + `include("precompile.jl")` last in `src/ChuiTypes.jl`; GREEN.
4. Check T2 (no residue, no precompile warnings) from a fresh precompile log, recorded as evidence.
5. After-measurement, both versions (`p5-ttfx-after`). Gates as in `p5-perf` step 8;
   `changelog.d/p5-ttfx.md`; `scripts/lane audit p5-ttfx`.

## Integration (sub-lead, lane `phase5`)

1. Reviewer FINAL per work lane; `scripts/lane audit <lane> --reported <report file>`.
2. Merge `feat/p5-perf`, then `feat/p5-ttfx`, into `feat/phase5` (`--no-ff`). Conflicts are not
   expected (disjoint scopes); any merge resolution is reviewed.
3. On `feat/phase5`: re-measure TTFX (the stream changes alter what the workload compiles) and
   write ADR-0009 "Performance budgets" (spec §5) + its `docs/adr/README.md` row. The ADR cites
   the ceilings in `test/test_perf.jl` / `test/test_precompile.jl`; it never restates different
   numbers. If the re-measure breaks a test ceiling, the owning work lane is reopened to fix it
   (the `phase5` lane owns no test file). A benchmarker agent, scope = the `phase5` lane's.
4. `ci.jl test -- all` on 1.13 and +lts, quality, jet, format, guards; HANDOFF.md refresh;
   `changelog.d/phase5.md`; `julia scripts/dod.jl --base main`.
5. Reviewer on the full `main...feat/phase5` diff until APPROVE (FINAL). Report to the lead.

## Rules every lane brief repeats

Repo `ChuiTypes.jl` only; write only inside the worktree's owned globs; Edit/Write tools only;
Python only via `uv`; bound runs with `julia scripts/ci.jl <job> --timeout S`; no push/tag/GitHub.
**Reference-repo rule:** the three private reference repos named in `.agents/factory.local.toml`
are read-only: read files only, never run anything there (no `uv run`, `julia --project`, make,
`sh -c` strings, or env-var project selection pointing there).
