# ADR-0002: The effect runtime interprets effects on Julia Tasks with cooperative cancellation

- **Status:** Proposed
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint (via the lead)
- **Scope:** ChuiTypes.jl

## Context

ChuiTypes owns exactly **one effect runtime** (`contracts/chui-types.md`, obligation 1). It needs:
- environment, error and success channels;
- resource safety;
- structured concurrency on `Task`s;
- propagating cancellation;
- retries, schedules and timeouts (brief 20).

The adapters are in ADR-0006. Facts from
[`docs/research/effect-runtimes.md`](../research/effect-runtimes.md) and from `.lanes/evidence/`
files (scripts in [`docs/research/scripts/`](../research/scripts/)), on 1.13.2 and 1.10.12:

- **Cancellation in Base.**
  - Base 1.10–1.13 has none (EFF-01).
  - `throwto` aborts 1.13.2 and hangs 1.10.12 on a running task (EFF-04).
  - 1.14-alpha adds token cancellation, from source only and not run (EFF-02).
- **`@sync` neither cancels siblings nor waits** when its body throws (EFF-07, EFF-08).
- **Scoped values.**
  - They reach child tasks (EFF-09).
  - On 1.13.2 a nested-scope read costs 22.1 ns and a `with` costs 19.8 ns.
  - `with` nested 10^4 deep is fine. At 10^5 the run prints "detected a stack overflow" twice
    and no result line (`crit-svflush-113`; the 1.10 backport was not measured).
- **Cost.** An interpreted bind costs about 25–60 ns, and a task spawn plus fetch about 15–19 µs
  median (EFF-12).
- **Stack safety.** A trampolined interpreter is safe at depth 10^6, while closure composition
  overflows, fatally on 1.13.2. A 2-step run costs 84–138 ns interpreted against 7–14 ns for
  closures (`effenc-110`, `effenc-113-guarded`).
- **Virtual-time determinism.**
  - With `Threads.@spawn` fibers, same-instant wake-ups ran in either order, and output was
    rarely visible when `advance!` returned (`crit-vt-{113,110}`: 160/40 and 128/72 splits).
  - Sticky `@async` fibers on one thread plus a wait for quiescence gave one order in 500/500
    runs (`crit-vtsticky-{113,110}`).
- **Prior art.** ZIO and cats-effect mask acquire and release and run finalizers LIFO. Kotlin
  and Trio wait for their children (EFF-15 to EFF-18).

## Decision

1. **Effects are data, interpreted.** `Effect{E,A}` wraps internal node structs, run by a
   trampoline **inside the calling `Task`**.
   - `A` is advisory: it is derived with `promote_op` by ADR-0001 §4's rule and never asserted.
   - `run(eff, T)` asserts a type `T` the user declares.
   - The step cost is about 25–70 ns, which suits I/O granularity, not inner loops.
2. **No scheduler of our own.** `fork`, `race` and the parallel combinators spawn
   `Threads.@spawn` tasks, except in test mode (§10). `Fiber{E,A}` is an owned handle holding
   the task, a cancel state and the outcome.
3. **Outcomes.**
   - `Exit{E,A}` is `Success(a)` or `Failure(cause)`. `Cause{E}` is `Fail(e)`, `Die(ex, bt)` or
     `Interrupted`, and the **error channel is the `Cause`**.
   - `run(eff)` (a `Base.run` method on the owned type) and `fetch(::Fiber)` return `a` or throw:
     - **`ex` itself** for `Die(ex)`, and for `Fail(e)` when `e isa Exception`;
     - `EffectFailed(e)` only for a non-exception `e`;
     - `Cancelled()` for `Interrupted`.
   - `runexit` returns the `Exit`.
4. **Cancellation is cooperative and level-triggered.**
   - Each fiber's cancel state is a **mutable reference**, and the fiber keeps it with its
     environment in interpreter-local state. Both are bridged into a `ScopedValue` once around
     each `Sync` call and each spawn (one `with`, about 20 ns). They are never bridged per step,
     so recursive `provide`/masking cannot overflow the stack. Because the bridged value is the
     reference, a later cancel is visible to `checkcancel()`.
   - The interpreter checks the state between steps. The runtime primitives (`delay`, `await`,
     `Queue` put/take, semaphore acquire) wait on "ready or cancelled" via a `Threads.Condition`
     notified on cancel.
   - There is never a `throwto`. Opaque code inside a `Sync` is cancellable only through
     `async`'s canceller (ADR-0006) or `checkcancel()`.
   - `uninterruptible(eff)` and `interruptiblemask(restore -> …)` mask the fiber's own state.
5. **Interrupting.** `interrupt!(f)` only signals, and `await(f)` waits; there is no combined
   `interrupt`, which Distributed exports (`crit-names2-{113,110}`). `await` is itself
   cancellable, so mutual interrupts cannot deadlock **outside masked regions**. Two masked
   releases that await each other can still deadlock (as in cats-effect), and the docs say so.
6. **Structured concurrency with `Scope`** (unrelated to the unexported
   `Base.ScopedValues.Scope`).
   - Every fork belongs to the enclosing scope, and the scope **waits** for its children on
     exit. `fork(forever(x))` without a join keeps the parent alive; this is documented, and
     there is no daemon fork in v0.1.
   - The first child failure cancels the siblings, and the scope fails with its original cause
     (the others suppressed).
   - Interruptions the scope caused itself are not failures. Cancelling a parent cancels its
     children.
7. **Resources.** `bracket(acquire, use, release)` and `acquirerelease` run `acquire` masked.
   Releases run LIFO, each masked and all of them even when one throws, and each receives the
   `Exit`.
8. **Racing and timeouts.**
   - `race(a, b)` is the first success; when both fail it fails with both causes. `racefirst`
     is the first outcome.
   - `timeout(eff, d)::Effect{E,Option{A}}` returns `none` on expiry; `timeoutfail(eff, d, e)`
     fails with `e` instead. The loser is interrupted and awaited.
9. **Environment and clock.** `provide(eff, services…)` and `service(S)` give a typed service
   map, and a missing service is `Die(MissingService(S))`.
   - The clock is a service read with `delay(d)` and `clocktime()`; there is no `Base.sleep`
     piracy and no `Dates.now`.
   - Schedules (`recurs`, `spaced`, `exponential`, `jittered`; PROVISIONAL) drive
     `retry(eff, schedule)`.
10. **Test mode.** `runtest(eff; clock = VirtualClock())` runs every fiber as a sticky `@async`
    task on one thread, `fromtask` thunks included.
    - It counts live and parked fibers. `advance!(clock, d)` returns once all of them are parked
      in runtime primitives; same-instant wake-ups run FIFO by scheduling sequence. **This order
      is guaranteed only in test mode.**
    - A fiber blocked in a Base wait would stop `advance!` from ever returning, so `advance!` has
      a diagnostic wall-clock timeout that names the fibers it is waiting for.
11. **Leaks and ^C.**
    - A live-fiber counter and an orphan counter (ADR-0006) back the stress tests.
    - An `InterruptException` reaching the root fiber cancels the root scope, then rethrows.
      Because it arrives at any safepoint, finalizers run **best-effort** there, and ^C is
      excluded from the "exactly once" properties.
12. **Julia 1.14.** Only the fiber's cancel state knows how cancellation is delivered, so a later
    ADR may forward it to `Base.CancellationTokenSource` once 1.14.0 is out and has been run.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Closure-composed effects | Not stack-safe; fatal on 1.13.2 (`effenc-*`). |
| Own green-thread scheduler | Duplicates Base and cannot preempt CPU loops (EFF-06, EFF-11). |
| One `Task` per bind | About 500× an interpreted step (EFF-12). |
| `throwto` cancellation | Corrupts running tasks (EFF-04). |
| `@sync` as the scope | No sibling cancellation; leaks children (EFF-07, EFF-08). |
| A `with` per step for the token and environment | About 20 ns per step, and overflows at depth 10^5 (`crit-svflush-113`). |
| Asserting the inferred `A` | Stale inference throws on correct programs (ADR-0001 context). |
| Interrupting children when the parent ends normally (ZIO) | Silently kills work. |
| `Effect{R,E,A}` with an environment type parameter | No intersection types to merge requirements. A ★ question, recommended against. |
| Multi-threaded virtual time | Nondeterministic (`crit-vt-*`). |
| CancellationTokens.jl / ConcurrentUtilities | Not scoped, and no 1.14 bridge (EFF-02, EFF-14). |

## Consequences

- Phase 3 property tests: every finalizer runs exactly once, LIFO, under cancellation at random
  steps (excluding ^C), with Supposition `@check record=false` plus `@test`. Stress tests check
  the counters.
- Streams (ADR-0003) build on `Queue`, `Scope`, the clock and test mode.
- Names are free in Base, Core and 61–64 loaded stdlibs, except `interrupt`, which is not used
  (`crit-names2-*`, `runtime-names-*`). They are proposed at the ★.

## Verification

- EFF-01 to EFF-20. In `.lanes/evidence/`: `effenc-*`, `crit-svflush-113`, `crit-vt-*`,
  `crit-vtsticky-*`, `crit-names2-*`, `runtime-names-*`.
- UNVERIFIED:
  - Julia 1.14 and 1.12;
  - the scoped-value cost on the 1.10 backport;
  - benchmarks on an idle machine;
  - the test-mode barrier itself (only its premise was checked).

## Revisit when

- Julia 1.14.0 is released, or phase 5 finds the interpreter on a hot path.
- The ecosystem raises its Julia floor to 1.11 or higher.
