- Phase 1 (Research and ADRs). Three verified research notes in `docs/research/`
  (`sum-types.md`, `effect-runtimes.md`, `streams.md`; runs on Julia 1.13.2 and 1.10.12). Six
  Proposed ADRs:
  - 0001 concrete parametric data types with one slot per variant payload;
  - 0002 an interpreted effect runtime on Julia `Task`s with cooperative cancellation and a
    deterministic test mode;
  - 0003 pull-based chunked streams with cancellable bounded queues;
  - 0004 a single ChuiCore adapter module;
  - 0005 dependencies (ScopedValues.jl, then ChuiCore);
  - 0006 adapters to `Task`, `Channel` and exceptions, through owned handles and cancellers.

  Spec: `docs/superpowers/specs/2026-10-20-phase1-research-design.md`. No code changes.
