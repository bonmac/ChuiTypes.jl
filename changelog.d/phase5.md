- Phase 5 (performance): ADR-0009 "Performance budgets" (Proposed) records the allocation, time
  and time-to-first-call budgets and the test that enforces each: `test/test_perf.jl` and
  `test/test_precompile.jl`. It also records the published losses (a slower package-image build,
  the fused-operator targets not met, `merge` over `Vector` sources slower) and the follow-ups.
  The spec is `docs/superpowers/specs/2026-10-26-phase5-performance-design.md`, and the plan is
  `docs/superpowers/plans/2026-10-26-phase5-performance.md`. The lane fragments `p5-perf.md` and
  `p5-ttfx.md` hold the code changes.
