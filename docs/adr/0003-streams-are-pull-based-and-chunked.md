# ADR-0003: Streams are pull-based and chunked, with cancellable bounded queues at task boundaries

- **Status:** Accepted (2026-10-20, user at the ChuiTypes phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint (via the lead)
- **Scope:** ChuiTypes.jl

## Context

Brief 20 asks for:
- cold and hot streams, and the Rx operators;
- schedulers, with virtual time for marble tests;
- backpressure;
- use as a ChuiFrames `Source`.

They run on the one runtime (ADR-0002). Facts from
[`docs/research/streams.md`](../research/streams.md), on 1.13.2 and 1.10.12:

- **Push or pull costs the same in one task:** about 0.3 ns per item (STR-17).
- **Task boundaries are expensive:**
  - one `Channel` handoff per item: 0.5–115 µs;
  - batches of 1024 through a small buffer: 1.5–23 ns per item (STR-17, STR-18).
- **Bounded channels block `put!`** (STR-12).
- **Abandoned channels leak producers** (STR-15).
- **Channel iteration does not surface errors on 1.10** (STR-13).
- **A parked `put!` on a Base `Channel` wakes only through `close` or `throwto`.**
  - With one shared output channel, closing it to cancel one producer kills the siblings too
    (`.lanes/evidence/crit-shared-{113,110}`: `A done after token: false`, then
    `A -> InvalidStateException, B -> InvalidStateException` on both versions).
  - `Base.waitany` does not exist on 1.10 (EFF-01).
- **A single-task virtual-time scheduler is deterministic** (STR-19). Multi-threaded fibers are
  not (ADR-0002 context).
- **Prior art.** fs2 and ZIO Streams pull in chunks (STR-04, STR-05). RxJS has no backpressure
  (STR-01). Rocket.jl pushes, with an unbounded default (STR-09).

## Decision

1. **`Stream{T}` is a cold description.** A run pulls **chunks**: each step returns a non-empty
   `AbstractVector{T}` (target length 1024, tunable) or the end. Building a stream starts no
   work. Each chunk crosses a function barrier, so in-chunk loops specialise.
2. **Element operators fuse inside chunks** through ADR-0004's transducer stand-ins
   (`Upstream.Map`, …; ChuiCore's names are PROVISIONAL).
   - Stateful operators (`scan`, `take`, `drop`) carry their state across chunks.
   - An early `Reduced`, such as `take` finishing, stops the upstream pull and closes the run's
     scope.
3. **Task boundaries use the runtime's `Queue{T}`** (ADR-0002 §4), never a Base `Channel`.
   - The queue is bounded, with a default capacity of 4 chunks.
   - `put!` and `take!` wait for space or an item, **or for the caller's own cancellation**.
   - A cancelled producer therefore wakes without closing a shared queue, and a blocked `put!` is
     the backpressure.
   - Base `Channel` appears only in the ADR-0006 adapters.
4. **Concurrent operators.** Each inner producer of `merge`, `mergeMap`, `switchMap`, the
   time-based `buffer`/`window` and `async` boundaries is a child fiber in the run's `Scope`.
   - `mergeMap` takes `maxconcurrent` (default 16).
   - `switchMap` tags chunks with a generation number and drops chunks from earlier generations.
     It interrupts the previous inner fiber **without** waiting on it, then awaits it after the
     handoff, so nothing waits on a drain only the waiter can perform.
5. **Hot sources** (subjects, timers, sockets) are built on ADR-0006 `async` with a canceller.
   - Each subscriber has its own bounded buffer, whose capacity is counted **in elements**
     (default 1024). The **overflow policy applies per element**:
     `:block` (the default), `:dropnewest`, `:dropoldest` or `:latest`.
   - With no subscribers, emissions are dropped, as with an Rx `Subject`.
   - Under `:block`, the slowest subscriber paces the publisher. A consumer that emits into its
     own blocked source deadlocks; this is documented, and `:dropnewest` is suggested there.
   - Hot sources emit partial chunks, so they never wait to fill 1024 items.
6. **Running a stream is an effect.** `runcollect`, `runfold` and `runforeach` (names PROVISIONAL)
   return `Effect`s. Streams have no scheduler or cancellation of their own (contract
   obligation 1).
7. **Scoped cancellation.** Every run owns a `Scope`. Leaving it, by end, `take`, error or
   interruption, interrupts the child fibers, awaits them and runs the finalizers LIFO.
   - A producer that is woken by its own cancellation ends `Interrupted`, not failed.
   - Joining never replaces the primary error.
   - A producer in a loop with no yield points cannot be interrupted; this is documented.
8. **Errors travel as values.** A failure is a terminal step carrying a `Cause`. It is never
   signalled through channel iteration.
9. **Time goes through the runtime clock.**
   - `debounce`, `throttle`, the time-based `buffer`/`window`, `retry` with a delay, `interval`
     and `timer` use `delay`/`clocktime` (ADR-0002 §9).
   - Marble tests run under `runtest` with a `VirtualClock` (ADR-0002 §10). A cold marble source
     schedules its events when it is subscribed, so same-instant ties follow subscription order.
   - Every time operator documents its tie behaviour.
   - Rx's `observeOn`/`subscribeOn` become one `async` boundary operator.
10. **A scoped batch handle for consumers such as ChuiFrames.** `withbatches(f, s)` (name
    PROVISIONAL) calls `f(it)`, where `it` iterates chunks (`SizeUnknown()`) and is valid only
    inside `f`. Leaving `f` closes the run. This ADR does **not** claim that this alone satisfies
    `chui-frames.md`'s Source sketch, which needs `source_schema` up front, re-readable partition
    handles with column selection, and `isthreadsafe`. That fit is ChuiFrames' adapter work and a
    cross-repo question (the lane's report).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Push core (RxJS / Rocket.jl) | No demand signal, and no faster (STR-01, STR-09, STR-17). |
| Monix `Ack` / Reactive Streams `request(n)` | A blocked, cancellable `put!` gives the same signal in one process (STR-02, STR-03). |
| Base `Channel` at internal boundaries | One producer cannot be cancelled without closing the shared channel (`crit-shared-*`), and iteration is silent on 1.10 (STR-13). |
| Per-element handoffs | 0.5–115 µs per item (STR-17). |
| Rocket.jl / Transducers.jl as the base | Push-only and unbounded / a 42-package closure (STR-09, STR-11). |
| Unscoped `iterate` on concurrent streams | Leaks producers (STR-15). |
| Unlimited `mergeMap` concurrency | A 1024-item chunk would spawn 1024 tasks at once. |

## Consequences

- Fused operators cost what an iterator does. Concurrency costs per chunk, not per item.
  - **Measured 2026-10-20 (phase 4), this claim is NOT met yet.** On 1.13.2, one thread, on a
    loaded machine (load average 19.9–22.6 on 12 cores), fused `map`/`filter` collect cost
    about 5.5× the Base equivalent on a `Vector` (median 3.84 vs 0.70 ns per element),
    `runfold` about 43× Base `foldl` (5.29 vs 0.12 ns), with about 24 allocations / 15 KB per
    1024-element chunk. The per-chunk concurrency claim is consistent: `merge`, `prefetch` and
    `mergemap` cost 3.4–7.1 ns per element. Evidence: `.lanes/evidence/bench-streams-bd8bcc0.txt`.
    Meeting the claim is a **phase-5 target**.
- Streams come after the runtime's `Queue`, `Scope`, clock and test mode (phase 3), so they land
  in phase 4.
- A chunk adds latency for sparse sources; partial chunks bound it, and phase 4 tests this.
- ChuiFrames' Source adapter needs a cross-repo design round (bounded vs streaming, schema).

## Verification

- STR-01 to STR-19; `.lanes/evidence/streams-tp-*` and `crit-shared-*`. Scripts are in
  [`docs/research/scripts/`](../research/scripts/).
- UNVERIFIED:
  - the 1.12 or 1.13 origin of the iteration change;
  - the libuv poll cost on Linux;
  - RxJS's tie rule;
  - `Queue` and test mode, which are designed but not built.

## Revisit when

- ChuiFrames decides its Source shape, or phase-4 benchmarks move the chunk or queue sizes.
- The Julia floor rises past 1.11, or Julia 1.14's cancellable `Channel` operations ship.
