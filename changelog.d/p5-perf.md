- Phase 5 (performance), stream hot path: `fromiter` over a `Vector`, an `AbstractRange` or a
  linear view of a `Vector` copies each chunk by index; the generic iteration source keeps an
  inferred, concrete state type; the fused sink is indexed and pre-sized, with its fill count in
  the pipeline accumulator; the fused puller, the run driver and `runfold` no longer box per
  chunk (`runfold` keeps a typed accumulator when `op` returns `typeof(init)`, never converting).
  On 1.13.2 a folded `fromiter(::Vector)` went from 2.50 to 0.36 ns per element and a fused
  `map`/`runfold` from 4.90 to 1.83; allocations per 1024-element chunk from 13–25 to 3–6
  (loaded machine; ADR-0003 "Measured 2026-10-26"). The fused-operator targets (2.5× and 10×
  Base) are not met.
- `Effect` binds allocate 1.95 instead of 7.96 times each (about 42 instead of 62 ns): the
  interpreter no longer boxes two captured variables on every step.
- `LazyList` forcing goes through a function barrier: a map/chain/fold over 1000 elements is
  about 4.9× faster.
- New `test/test_perf.jl`: allocation budgets per stream chunk and per bind, per Julia version
  (1.13, 1.10). New property and unit tests: the indexed `fromiter` path equals the generic path
  (`test/test_stream_fastpath.jl`). New benchmark rows: `fromiter` source-only (Vector, generic
  iterator) and the interpreters' allocations per bind.
- Internal, no public API change: `fromiter`'s docstring adds that a `Vector` is read as it is at
  each chunk (as before).
