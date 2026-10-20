# Architecture Decision Records

Package-level decisions for this repo. Ecosystem-wide decisions live in the coordinator's
`adr/`. New ADRs start from [`0000-template.md`](0000-template.md); one decision per file,
about 60–120 lines, titled as a claim. Keep this index current in the same commit.

| # | Title | Status |
|---|---|---|
| 0000 | [Template](0000-template.md) | — |
| 0001 | [Data types are concrete parametric structs with one slot per variant payload](0001-data-types-are-concrete-parametric-structs.md) | Accepted (2026-10-20, user at the ChuiTypes phase-1 ★); §4 amended 2026-10-20 (phase-2 ★ answer relayed by the lead) |
| 0002 | [The effect runtime interprets effects on Julia Tasks with cooperative cancellation](0002-effect-runtime-on-julia-tasks.md) | Accepted (2026-10-20, user at the ChuiTypes phase-1 ★) |
| 0003 | [Streams are pull-based and chunked, with cancellable bounded queues at task boundaries](0003-streams-are-pull-based-and-chunked.md) | Accepted (2026-10-20, user at the ChuiTypes phase-1 ★) |
| 0004 | [Every use of ChuiCore goes through one adapter module](0004-one-adapter-module-to-chuicore.md) | Accepted (2026-10-20, user at the ChuiTypes phase-1 ★) |
| 0005 | [Runtime dependencies are ChuiCore and ScopedValues.jl only](0005-dependencies.md) | Accepted (2026-10-20, user at the ChuiTypes phase-1 ★) |
| 0006 | [Adapters to Task, Channel and exceptions go through owned handles and cancellers](0006-adapters-to-task-channel-and-exceptions.md) | Accepted (2026-10-20, user at the ChuiTypes phase-1 ★); obligation-2 contract ADR pending in the coordinator |
| 0007 | [Reader, Writer and State are erased node trees with a declared parameter, run by a pure trampoline](0007-reader-writer-state-are-erased-node-trees.md) | Accepted (2026-10-20, user at the phase-3 ★) |
| 0008 | [A bounded stream becomes a ChuiFrames Source by a snapshot taken at construction](0008-a-bounded-stream-becomes-a-source-by-snapshot.md) | Proposed (phase 4; critic ACCEPT WITH FIXES, fixes applied) |
