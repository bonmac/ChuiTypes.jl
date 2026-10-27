# Plan: `scan` widens its accumulator (2026-10-27)

Tier T1. Test-first lane `scan-widen` (factory 0.3.0, ADR-0015 in the coordinator), mode `required`.
It is also the coordinator's live smoke lane for the test-writer role (0.3.0 critic C5).

## Task 1: `scan` widens its accumulator type like `Base.accumulate`

**Problem.** ADR-0009 follow-up 4: `scan` cannot change its accumulator type.
`collect(scan(+, 0, fromiter([1, 2.5, 3])))` throws on `convert`, because the accumulator stays
the type of `init`.

**Expected behaviour.** `scan(op, init, s)` emits the running accumulations `op(acc, x)`,
starting from `init`, which is not emitted. It must give the same values, in the same order, as
`Base.accumulate(op, collect(s); init = init)`, including when `op(init, x)` has a wider type
than `init`. The stream's element type covers every emitted value.
- `collect(scan(+, 0, fromiter([1, 2.5, 3])))` returns `[1.0, 3.5, 6.5]` (`Float64`).
- `collect(scan(+, 0, fromiter([1, 2, 3])))` keeps returning `[1, 3, 6]` (`Int`), the existing
  behaviour.
- The accumulator is still carried across chunks: the result does not depend on chunking.
- An empty stream gives an empty result.

**Out of scope:** `fold`/`runfold`, other operators, and performance budgets. The ADR-0009 `scan`
rows must stay green.

**Files:** `src/stream/fused.jl` and `src/upstream.jl` (implementer);
`test/test_stream_scan_widen.jl` (test-writer, new).

## Spec

- The `scan` docstring in `src/stream/fused.jl`, as rendered by `julia scripts/tdd.jl api`.
- ADR-0003 (streams are pull-based and chunked: stateful operators carry state across chunks).
- ADR-0009 follow-up 4.
- `Base.accumulate` as the reference semantics.
