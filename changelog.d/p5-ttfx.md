- Time to first call (phase 5, spec `docs/superpowers/specs/2026-10-26-phase5-performance-design.md`
  §4): a dependency-free precompile workload (`src/precompile.jl`, run only while generating the
  package image; no new dependency) over Option, Either, Validation, effects, `fork`/`await`,
  `State` and streams. Fresh-process first-call workload total, median of 7, one thread, Apple M3
  Pro (1-min load 4.9–5.6 before, 3.9–4.3 after: loaded): 1.77 s → 0.28 s on Julia 1.13.2,
  1.30 s → 0.18 s on 1.10.12. Costs: package image build (compilecache) 0.65 s → 1.98 s (1.13)
  and 0.71 s → 2.01 s (1.10); load time 0.012 s → 0.018 s (1.13) and 0.021 s → 0.039 s (1.10).
  Effects in the workload are `run` through a `Ref{Any}` so JET's `report_package` does not
  follow them into the interpreter (6 false positives otherwise). Evidence
  `.lanes/evidence/p5-ttfx-before-339c806.txt`, `p5-ttfx-after-4f44bfd.txt`.
- `benchmark/ttfx.jl`: the fresh-process TTFX measurement (load, per-entry first call, total,
  optional compilecache, load average). `test/test_precompile.jl`: the workload leaves no live
  fiber or orphan (`:unit`), and a `:slow` regression ceiling (0.6× the pre-workload baseline per
  Julia version).
