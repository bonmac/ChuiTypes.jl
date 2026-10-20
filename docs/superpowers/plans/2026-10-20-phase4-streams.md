# Phase 4 plan: futures and streams

- **Spec:** `docs/superpowers/specs/2026-10-20-phase4-streams-design.md` (T2).
- **Written retroactively** (review S5). The lane wrote the spec, had it critiqued, then wrote the
  tests before the code, but kept the task order below in its working notes rather than in this
  file. `dod.jl` classified the branch T1, so it did not ask for a plan: new exports in
  `src/ChuiTypes.jl` match no T2 protected glob. That blind spot goes to the lead as a draft
  request (`.agents/checks.toml` and `risk.toml` are T3).

## Tasks, in the order they were done

| # | Task | Files | Gate |
|---|---|---|---|
| 1 | Spec, ADR-0008 draft; critic round (ACCEPT WITH FIXES), fixes folded in | spec, `docs/adr/0008-*` | critic |
| 2 | Tests first: queue, stream, marbles, hot, adapters, source, futures, properties + planted, laws, stress | `test/test_queue.jl`, `test/test_stream*.jl`, `test/test_futures.jl`, `test/laws/test_laws_stream.jl` | RED (nothing built) |
| 3 | Transducer stand-ins | `src/upstream.jl` | fusion tests |
| 4 | Queue | `src/stream/queue.jl` | `test_queue.jl` |
| 5 | Stream core, sources, run functions, `withbatches`, `runchunks` | `src/stream/core.jl` | `test_stream.jl`, `test_stream_source.jl` |
| 6 | Fused operators | `src/stream/fused.jl` | fusion tests, property S1 |
| 7 | Sequential combinators | `src/stream/sequential.jl` | `test_stream.jl` |
| 8 | Pumps, merge, prefetch, mergemap, switchmap | `src/stream/concurrent.jl` | marbles, property S2 |
| 9 | Time operators, virtual-clock sequence reservation | `src/stream/time.jl`, `src/effect/clock.jl` | marbles |
| 10 | Subject; Channel adapters; marbles; collectpar | `src/stream/hot.jl`, `adapters.jl`, `marbles.jl`, `futures.jl` | hot, adapters, marble round trip, futures |
| 11 | Benchmarks (sub-lane); ADR-0003 "Measured" note | `benchmark/benchmarks.jl`, ADR-0003 | evidence `bench-streams-*` |
| 12 | Gates on 1.13.2 and 1.10.12 under a process-group alarm; JET; docs; dod; lane audit | — | outputs in the lane report |
| 13 | Review round 1 (REJECT): B1 cancel checks, B2/S3 pump leases and close causes, S4 property S5 + planted, N6 window index, N7 docs, N8 Subject conversion; each new test shown RED, then GREEN | `src/stream/{fused,time,concurrent,hot,core}.jl`, `test/test_stream.jl`, `test/test_stream_props.jl`, `test/test_stream_hot.jl` | re-review |
