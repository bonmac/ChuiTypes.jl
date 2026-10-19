# Spec: ChuiTypes phase 1, research and ADRs

- **Date:** 2026-10-20
- **Lane:** `phase1-research` (branch `feat/phase1-research`), tier T2 (public API shape, dependencies)
- **Status:** awaiting the ★ checkpoint. Nothing is implemented in this phase.

## Goal

Brief 20, phase 1: decide a type-stable encoding of the data types, the effect runtime (fibers or
`Task`s, and cancellation) and the stream design (push or pull, and backpressure) before any code
is written. Also decide the adapter boundary to the unreleased ChuiCore, the adapters the contract
requires, and every proposed dependency. Then report to the lead at the ★.

## Deliverables

| Deliverable | Path |
|---|---|
| Research: sum and option types | [`docs/research/sum-types.md`](../../research/sum-types.md) (SUM-01 to SUM-13) |
| Research: effect runtimes | [`docs/research/effect-runtimes.md`](../../research/effect-runtimes.md) (EFF-01 to EFF-20) |
| Research: streams | [`docs/research/streams.md`](../../research/streams.md) (STR-01 to STR-19) |
| ADR-0001 type encoding | [`0001`](../../adr/0001-data-types-are-concrete-parametric-structs.md) |
| ADR-0002 effect runtime | [`0002`](../../adr/0002-effect-runtime-on-julia-tasks.md) |
| ADR-0003 streams | [`0003`](../../adr/0003-streams-are-pull-based-and-chunked.md) |
| ADR-0004 ChuiCore adapter | [`0004`](../../adr/0004-one-adapter-module-to-chuicore.md) |
| ADR-0005 dependencies | [`0005`](../../adr/0005-dependencies.md) |
| ADR-0006 Task/Channel/exception adapters | [`0006`](../../adr/0006-adapters-to-task-channel-and-exceptions.md) |

## The design, by ADR

- **Data types (ADR-0001).**
  - Every type is a concrete parametric struct. Each variant payload gets its own
    `Union{Nothing,X}` slot, plus a tag.
  - That layout is the only one measured to make 0 allocations for pointer payloads:
    `Option{String}`, `Either{String,Int}`.
  - Constructors carry the missing type.
  - The parameter in empty and left branches comes from `promote_op` and is never asserted.
  - Equality, `hash` and `show` look only at the active slots.
  - Each type has a table of typeclass instances; `Validation` has no Monad instance.
  - The encoding of `Reader`, `Writer` and `State` is deferred to phase 3, under stated
    constraints.
- **Effect runtime (ADR-0002).**
  - `Effect{E,A}` is data. A trampoline interprets it inside the calling `Task`, and `A` is
    advisory.
  - `fork`, `race` and the parallel combinators spawn Tasks.
  - The outcome is `Exit`, with a `Cause` of `Fail`, `Die` or `Interrupted`; the error channel
    is the `Cause`.
  - Cancellation is cooperative and level-triggered. It lives in fiber-local state that is
    bridged into a `ScopedValue` only around `Sync` calls and spawns. It wakes the runtime's own
    primitives and never uses `throwto`.
  - `interrupt!` only signals; `await` waits for the fiber.
  - Scopes wait for their children. Interruptions a scope causes itself are not failures.
  - Finalizers run LIFO and masked.
  - `race` settles on the first success; `timeout` returns an `Option`.
  - The clock and environment are services, with `delay` and `clocktime`.
  - A single-thread test mode with a quiescence barrier makes virtual time deterministic.
  - A live-fiber counter supports leak tests.
- **Streams (ADR-0003).**
  - A cold `Stream{T}` is pulled in chunks. Element operators fuse inside a chunk and carry state
    across chunks.
  - Task boundaries use the runtime's cancellable bounded `Queue`, never Base `Channel`.
  - `switchMap` uses generation tags; `mergeMap` has a `maxconcurrent` limit.
  - Hot sources have a per-subscriber, per-element overflow policy.
  - Errors are values. Time goes through the clock.
  - `withbatches` is a scoped batch handle. It does not claim to fit ChuiFrames' Source sketch.
- **ChuiCore boundary (ADR-0004).**
  - `ChuiTypes.Upstream` is the only module that mentions ChuiCore; a `\bChuiCore\b` grep test
    enforces it.
  - It holds stand-ins (ChuiTypes' proposals) until a ChuiCore snapshot exists.
  - Switching over is a one-file change only when names and the encoding match.
  - No typeclass operation names are exported.
  - Law tests stay local until ChuiCore ships its kits.
  - Requests R1 to R5 go to ChuiCore.
- **Dependencies (ADR-0005).** ScopedValues `"1.6"` from phase 3, ChuiCore at its first snapshot,
  and Compat only for `@compat public`. Nothing else.
- **Adapters (ADR-0006).**
  - `async(register)` takes a canceller. Hot sources and `fromtask` are built on it.
  - `fromtask` produces `Fail(original)`. Cancelling it without a canceller abandons the task,
    and the abandonment is counted.
  - `fetch` on a `Fiber` throws the original exception. `totask` gives a Base `Task`, whose
    `fetch` wraps the error, unavoidably.
  - `fromchannel` reads with `take!`.
  - IO, futures and the task-like type are constructors of `Effect`, not types.

## Testing rules carried into phases 2–4

- **Property and law tests** use Supposition as `@check record=false` plus an explicit `@test`.
  The lead reproduced the reason: Supposition 0.3.5 does not record a failing `@check` inside
  `@testset` on 1.10.12. The amendment to root ADR-0007 §2 goes to the user.
- **Value types:** `isconcretetype` and `@inferred` on chains. Zero-allocation benchmarks for
  `Option{Int}`, `Option{String}` and `Either{String,Int}`.
- **Effects:** property tests that every finalizer runs exactly once, in LIFO order, under
  cancellation at random steps. Round-trip tests for every adapter. Stress tests where the
  live-fiber and orphan counters return to zero.
- **Streams:** marble tests under `runtest` with a `VirtualClock`. Early-exit, leak and
  `switchMap` generation tests.

## Contract consistency (against `contracts/chui-types.md` v0)

- **Obligation 1 (one runtime): consistent.** There is no second scheduler or cancellation
  mechanism (ADR-0002 §2, ADR-0003 §6, ADR-0006 §6).
- **Obligation 2 (adapters): two conflicts, and one wording question for the lead.** These are
  notes, not contract edits.
  - **C1, Effect → Task.** "An effect failure is thrown from `fetch` as the original exception"
    is impossible for a Base `Task`, because `fetch` always wraps it in `TaskFailedException`
    (EFF-05; the critic ran it on both versions). ADR-0006 §3 meets the rule on the owned
    `Fiber` handle. On a Base `Task`, `task.exception === original`. Proposed contract wording
    is in ADR-0006 "Consequences".
  - **C2, Task → Effect cancellation and the round trip.** A started foreign `Task` cannot be
    stopped without a canceller (EFF-04, EFF-09). ADR-0006 §2 runs the canceller if there is
    one, and otherwise abandons the task and counts the abandonment. A round trip through a
    foreign task therefore keeps the result and the failure, but keeps cancellation only with a
    canceller.
  - **C3, wording.** "A value in the error channel" means a `Cause`: a `Die(ex)` for a thrown
    exception, and a `Fail(ex)` with `E = Exception` from `fromtask`.
- **CT-003: consistent.**
  - No `IO`, `Task`, `Future`, `Error`, `sleep`, `now` or `interrupt` binding. `interrupt` is
    Distributed's, so the runtime uses `interrupt!` plus `await`.
  - `run`, `retry`, `fetch`, `map` and `filter` are Base methods on owned types.
  - Every proposed name was checked against Base, Core and the loaded stdlibs (29 in the lane's
    scripts, 61–64 in the critic's) on both versions (`names-*`, `ctor-names-*`,
    `runtime-names-*`, `crit-names2-*`).
- **PROVISIONAL items.** Names and semantics are proposals. Each becomes a CT entry only after
  the user accepts it at the ★ (root ADR-0010).
- **Source adapter.** ChuiTypes ships no ChuiFrames extension; the adapter is ChuiFrames' to write
  (root ADR-0002 §1). Whether `withbatches` is enough is a cross-repo question.

## Out of scope

Implementation, `Project.toml`, contract edits and coordinator requests. Requests are drafted in
the lane's report for the lead to file.
