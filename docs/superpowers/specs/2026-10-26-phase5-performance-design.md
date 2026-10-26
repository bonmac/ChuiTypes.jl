# Phase 5: performance (allocations and TTFX): design

- **Date:** 2026-10-26. **Tier:** T1 per lane (internal changes, no public API, no new dependency,
  no contract change). ADR-0009 is a new package ADR (performance budgets), docs only.
- **Inputs:** BRIEF phase 5; HANDOFF "Phase 5"; ADR-0003 "Measured 2026-10-20"; the measurement
  report `.lanes/reports/types-p5.md` and its evidence `.lanes/evidence/*p5*-08e9468.txt`
  (head 08e9468, 1.13.2, one thread, load average 1-min 2.4–6.0, 5/15-min 50–70: **indicative**).
- **Lead decisions (2026-10-26):** TTFX uses a dependency-free precompile workload guarded by
  `ccall(:jl_generating_output, Cint, ()) == 1`, **not** PrecompileTools; no ADR-0005 change.
  Phase-5 item 1 (switch `Upstream` to ChuiCore 0.0.1) stays **blocked** and is out of scope.

## 1. Problem (from the evidence)

Per 1024-element chunk, 10^6 elements (`p5-allocs`, `p5-timing`, `p5-micro`):

| case | ns/elem (median) | allocs/chunk |
|---|---|---|
| Base map/filter collect | 0.51 | — |
| Base map foldl over a Vector | 0.077 | — |
| S1 fused map/filter collect | 3.68 | ~20 |
| S2 fused map runfold | 4.67 | ~24 |
| S4 `fromiter(::Vector)` runfold (source only) | 2.35 | ~13 |

Confirmed causes, by site (08e9468):
1. **Sink growth in the fused puller.** The fused sink (fused.jl:31) and `_emit!` (core.jl:159)
   start each output chunk with a fresh `T[]` with no size hint, so `_sinkpush` (core.jl:141)
   reallocates its Memory 5–6 times per chunk: the top allocation site in bytes. (`fromiter`'s
   own sink is size-hinted, core.jl:196, but `_emit!` then allocates a replacement `T[]` that is
   thrown away.)
1a. **Per-chunk `_Ctx` and closure.** One `_Ctx` per chunk at fused.jl:53 and one `_drive`
   closure allocation per chunk at core.jl:115 (`p5-allocs`, S1/S2/S4 blocks).
2. **Source copy.** `fromiter` iterates element by element through a sink even when `itr` is
   already a `Vector`; about half of the fused time (S4).
3. **Per-chunk boxing in the generic source.** `_IterP.state::Any` boxes the iterator state and
   the `(chunk, st, more)` tuple (core.jl:183/186): 4–5 small allocations per chunk.
4. **Per-chunk dynamic dispatch in the fused puller.** `_FusedP._pull!` calls `_runchunk` on an
   untyped chunk (fused.jl:53/63), which heap-allocates the reducing function per chunk.
5. **`runfold`'s accumulator** (`Ref{Any}`) is **refuted** as a time cost (A1 no faster), but
   `_foldchunk` boxes the result twice per chunk (core.jl:369).
6. JET `report_opt` runtime-dispatch sites in the per-chunk path: core.jl:143/183/186,
   fused.jl:53/63; LazyList lazylist.jl:88/92/93. The 31 interpreter reports are expected
   (erased node trees, ADR-0007) and are triaged, not removed.
7. **TTFX** (fresh process, median of 7): first-call workload 1.69 s on 1.13.2 (1.23 s on 1.10),
   dominated by `andthen` (~0.46 s) and `merge` (~0.56 s). The dep-free prototype
   (`.lanes/p5-ttfx/pkg_depfree/`) measured 0.27 s (1.13) / 0.15 s (1.10); compilecache rose from
   ~0.7 s to ~2.0–2.3 s.
8. Allocations per bind for `Effect` and `State`: **not measured yet**.

## 2. Invariants that constrain the fixes (must not change)

- I1. **A returned chunk is never mutated by its puller** (core.jl protocol comment). So no
  buffer is reused after `_emit!` hands it out: "reuse" means *pre-sizing the next buffer*, not
  recycling the emitted one. `runchunks` returns owned, fresh vectors (ADR-0008).
- I2. Element types: a chunk is a `Vector{T}` of the advisory `T` while every element `isa T`,
  else narrowed (`map(identity, …)`), never `convert` (ADR-0002 §1). Output vectors from
  `runcollect` keep the tightest element type they have today.
- I3. Cold semantics: each run re-reads the source from its start. For a vector source, each pull
  reads the vector as it is at that pull (length re-checked per pull; elements copied out).
- I4. Cancellation is checked at every chunk boundary (`_spull!`), `take` closes upstream at once,
  failures stay values. Chunk sizes stay `chunksize` (the last may be shorter).
- I5. No public API change, no new dependency, no change to `Project.toml`.

## 3. Design, lane `p5-perf`

- D1. **Pre-sized sink.** `_Sink{T}` carries a capacity hint (`cap::Int`): the **last emitted
  chunk's length** (at least 1, at most the chunk size), so a sparse `filter` does not keep an
  oversized buffer in every `runchunks` chunk. `_emit!` replaces `s.v` with a vector given
  `sizehint!(…, cap)`. A sink used for exactly one emit (`_fillchunk`) hands its vector out
  without allocating a replacement (a separate "take" function). Expected: one Vector + one
  Memory per emitted chunk, no regrowth.
- D2. **Indexed fast path in `fromiter`.** Only for `itr::Array{T,1}`, `itr::AbstractRange` and
  `SubArray`s of a `Vector` with `IndexStyle === IndexLinear()` (no other `AbstractVector`:
  their `getindex` may return non-`eltype` values or their axes may be fixed at iteration start).
  `_open` returns an indexed puller with a typed `Int` cursor **starting at `firstindex(itr)`**
  (offset axes, e.g. `Base.IdentityUnitRange(3:5)`); each pull re-reads `lastindex(itr)` and
  copies `min(chunksize, remaining)` elements into a fresh `Vector{eltype(itr)}`: `copyto!` only
  when `isbitstype(eltype(itr))`, else an element loop through `getindex`, so an undef slot
  throws `UndefRefError` (a `Die`, as iteration does today). Chunk `eltype` exactly as the
  iteration path gives. Other iterators keep the generic path.
- D3. **Generic source without boxing.** `_IterP` keeps the state behind a function barrier so the
  per-chunk tuple and state are not boxed where the state type is concrete: `_IterP{I, S}` with
  `S` an **inferred** state type (`Base.promote_op` over `iterate(itr)` and `iterate(itr, s)`,
  concrete only when both agree), else `Any`. Never the runtime type of the first state (an
  iterator whose state type changes would fail the field assignment).
- D4. **Fused puller: one dispatch, no allocation per chunk.** `_FusedP._pull!` hands the chunk to
  a function barrier specialised on the chunk type; `rf`, `acc` stay concretely typed fields. The
  one dynamic call per chunk (`_spull!(p.up, …)` on an erased upstream) is allowed, but the
  per-chunk `_Ctx` allocation (fused.jl:53) and the `_drive` closure allocation (core.jl:115)
  are removed or, if they cannot be, explained with the profiler line in the report.
- D4a. **File size.** `ratchets.toml` caps `src/*.jl` (`*` matches `/`) at 600 lines; core.jl
  has 466. If D2/D3 push it past ~560, put the sources in a new file (sources.jl) under
  `src/stream/`, **included from `src/stream/core.jl`** (lane `p5-perf` does not edit `src/ChuiTypes.jl`).
- D5. **`runfold`**: avoid the double box per chunk (typed accumulator when `op`'s return type is
  concrete and equals `typeof(init)`, else today's `Ref{Any}`). Only if measured to help.
- D6. **LazyList** JET sites (lazylist.jl:88/92/93): fix if a local change removes them without a
  behaviour change; otherwise record why in the report.
- D7. **Effect and State per-bind allocations**: measure (`@allocations`/`@allocated` per bind
  over 10^4 binds, both Julia versions); optimise only a single dominant site with a local change,
  else record the numbers as the budget baseline.
- D8. **Allocation budget tests**: a new `test/test_perf.jl`, tag `:unit` (runs in CI on 1.13 and
  1.10): warmed `@allocations` per source chunk for S1, S2, S4 (Vector and range sources), a
  generic iterator source, and per bind for Effect and State, each asserted `<=` a budget row
  (measured value plus stated headroom, version-specific where they differ). These are the
  machine checks of the ADR-0009 allocation rows. Calibration: bounds are measured **as CI runs
  them**, through `julia scripts/ci.jl test` (`Pkg.test`, `--check-bounds=yes`), inside a
  function, after a warm-up call, and on both 1.13 and 1.10. Rows are keyed by
  `VERSION.major.minor`; on a version without a row (`pre`, 1.11, 1.12) the item measures and
  `@info`s, and asserts only a loose ceiling (2× the 1.13 row). When
  `Base.JLOptions().code_coverage != 0` (the coverage CI job) the item is skipped with an
  `@info` (`@test_skip`). Time is **not** asserted in tests (noisy);
  time rows live in `benchmark/benchmarks.jl` (warning-only CI, ADR-0011 of the coordinator).
- D9. **Benchmarks**: add `fromiter(::Vector)` source-only, generic-iterator source, and the
  Effect/State per-bind allocation report to `benchmark/benchmarks.jl`; keep existing rows' names.
- D10. **Docs of the cost**: update the `Stream` docstring's "Cost, measured" paragraph and add an
  ADR-0003 "Measured 2026-10-2x (phase 5)" bullet (dated, the 2026-10-20 bullet kept) with the
  after numbers, the load average and the evidence file.

**Targets** (on a quiet machine; directional, not test gates): S1 ≤ 2.5× Base collect; S2 ≤ 10×
Base foldl over a Vector; S4 ≤ 0.6 ns/elem; allocations per chunk: S4 ≤ 4 (Vector + Memory +
at most two more; 5 if D5 does not remove `_foldchunk`'s boxes), S1/S2 ≤ 8. A missed
target is reported with its numbers, not hidden; the sub-lead decides whether to stop for the lead
("a budget you cannot meet").

## 4. Design, lane `p5-ttfx`

- T1. `src/precompile.jl`: a function `_workload()` exercising, through public API only: Option,
  Either, Validation chains (`map`, `Upstream.chain`, `foldl`); `succeed`/`andthen`/`run`;
  `fork`/`await`; `State` (`getstate`/`putstate`/`modifystate`/`runstate`); streams:
  `fromiter` over a range and a Vector, `map`/`filter`/`scan`, `runcollect`, `runfold`, `merge`.
  It runs only when `ccall(:jl_generating_output, Cint, ()) == 1`; included last from
  `src/ChuiTypes.jl`. Plus explicit `precompile(…)` statements for non-closure entry points.
- T2. **No residue**: after `_workload()` no fiber, task or timer is alive (`livefibers()` empty,
  no `orphans()`). The machine gate is Aqua's persistent-tasks check, already run by
  `Aqua.test_all` (test/test_package.jl:60): it must stay enabled and pass with the workload in
  place. The precompile log of a fresh compile is also recorded as evidence (supporting, not a
  gate).
- T3. Tests (`test/test_precompile.jl`): `:unit` item that calls `ChuiTypes._workload()` and checks
  it returns `nothing` and leaves no live fibers; `:slow` item that runs the TTFX script in a fresh
  process (`Base.julia_cmd()`, so the child shares the parent's flags and cache), discards one
  warm-up repetition, takes the minimum of 3, and asserts a **regression ceiling**, not the
  target: the workload total `<=` 0.6× the pre-workload baseline (1.69 s on 1.13, 1.23 s on 1.10:
  ≈1.0 s and ≈0.75 s), i.e. it fails only when the workload stopped working. The ceiling values
  live in this test file; ADR-0009 cites them (one source of the numbers).
- T4. `benchmark/ttfx.jl`: a fresh-process TTFX measurement (load time, per-entry first-call
  time, total) with N repetitions, printing medians and the load average; run through
  `julia scripts/evidence.jl ttfx -- …`.
- T5. Before/after: baseline from `main`/`feat/phase5` vs the lane, both versions (1.13.2, 1.10
  LTS), plus compilecache time.

**Targets:** workload total ≤ 0.40 s on 1.13 and ≤ 0.30 s on 1.10 (quiet machine); load time
≤ 0.05 s; compilecache ≤ 3.0 s.

## 5. ADR-0009 "Performance budgets" (after both lanes merge)

A new package ADR (docs only, on `feat/phase5`): the budget table, which **cites** the tests'
numbers rather than restating new ones (allocation rows = the values `test/test_perf.jl` asserts;
TTFX rows = the measured medians plus the ceilings `test/test_precompile.jl` asserts; time rows =
the benchmark medians with the tolerance of `ratchets.toml` `bench.time_tolerance`), each with
machine, Julia version, threads, load average and evidence file. If the integrated re-measure
breaks a test ceiling, that is fixed on the owning work lane (reopened), not on `phase5`. It also
records the lead's dep-free-workload decision and why PrecompileTools was rejected (ADR-0005 §2),
and the triage of the remaining JET `report_opt` sites. The TTFX rows are re-measured on the
integrated branch (the stream changes alter what the workload compiles). Indexed in
`docs/adr/README.md`.

## 6. Out of scope

- The ChuiCore 0.0.1 switch-over (blocked). Concurrency operators' costs (merge, prefetch,
  mergemap) beyond keeping their benchmarks green. Interpreter redesign. Thread-count tuning.

## 7. Risks

- R1. Allocation counts differ between 1.10 and 1.13: the budget rows are per version.
- R2. A heavily loaded machine skews time and TTFX: every measurement records `uptime`; time
  targets are judged on the quietest run, and a loaded run is labelled.
- R3. Precompile workloads with tasks can hang or warn at the end of precompilation: T2 checks it.
- R4. A typed `fromiter` fast path could change element types for unusual `AbstractVector`s:
  property test "fast path == generic path" (same elements, same `eltype` of every chunk, same
  chunk lengths, same failure) over Vector, ranges, `Base.IdentityUnitRange(3:5)` (offset
  axes), `Vector{Any}`, `Vector{Any}(undef, 3)` (must fail with `UndefRefError` on both paths),
  `Vector{Union{Int,Missing}}`, views, a `Vector` resized between pulls, and an iterator whose
  state type changes (D3).
- R5. Coverage and `--check-bounds=yes` may change allocation counts: D8 calibrates under
  `ci.jl test` and skips under coverage.
