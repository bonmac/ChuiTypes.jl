# Research: effect runtimes and cancellation

Date: 2026-10-20. Lane: researcher, ChuiTypes phase 1. Status: evidence for the effect-runtime ADR.

## How verified

Julia behaviour was checked by running scripts on Julia 1.13.2 (`julia +release`) and 1.10.12
(`julia +lts`), with `-t 4`, and on 1.11.7 (`julia +1.11.7`) where noted. 1.12.5 has no binary
in the local juliaup tree (its `bin/` is empty), so 1.12 claims come from its installed Base
source only. Scripts live in
`/private/tmp/claude-501/-Users-bonmac-personal-projects-julia-data-analysis/5c1f011c-1151-4765-9a79-8eba6d64f4e6/scratchpad/types-p1/effects/`
(`01_api.jl` … `09_safe.jl`, `run.sh` adds a 30 s watchdog; envs `env13/`, `env10/`).
They are cited below by file name. Package facts come from the local General registry snapshot
(`~/.julia/registries/General.tar.gz`, read on 2026-10-20), installed package source, and
GitHub metadata (`gh api`, 2026-10-20). Other-language prior art comes from Context7 (IDs
given) or the project's own source/README. Benchmarks ran on a heavily loaded machine
(load average 37–62 on 12 cores, printed in the evidence files), so absolute numbers are
noisy; ratios are what matter.

## Julia facts

### EFF-01 No task-cancellation API in Base 1.10–1.13
Claim: Base has no `cancel`/`cancel!`/`CancellationToken` in 1.10.12, 1.11.7, 1.12.5 or
1.13.2. The only related tools are `schedule(t, exc; error=true)`/`Base.throwto`,
`Base.Experimental.@sync` (all versions), and `Base.Experimental.wait_with_timeout`
(1.12+; its source comment says it "will likely be dropped when a cancellation framework is
added").
Source: `01_api.jl` on 1.13.2/1.11.7/1.10.12; `grep -c wait_with_timeout share/julia/base/experimental.jl`
gives 0 (1.10.12), 0 (1.11.7), 5 (1.12.5), 7 (1.13.2).
```
1.13.2: Base.cancel false  Base.cancel! false  Base.CancellationToken false  Base.Experimental.cancel false
        Base.ScopedValues true  Base.waitany true  Base.Lockable true
        Base names matching cancel: [:UV_EAI_CANCELED, :UV_ECANCELED]
1.10.12: Base.cancel false  Base.cancel! false  Base.CancellationToken false
         Base.ScopedValues false  Base.waitany false  Base.Lockable false
1.11.7: no cancel names; Base.ScopedValues true; Base.Lockable true
```

### EFF-02 Julia 1.14 (alpha) adds native, token-based task cancellation
Claim: `release-1.14` (VERSION `1.14.0-alpha1`, tag commit b8b5bddd24, 2026-10-19) and master
(`1.15.0-DEV`) contain `base/cancellation.jl`; `release-1.13` does not (404). NEWS for v1.14:
"Task cancellation is now supported, organized around cancellation tokens:
`Base.CancellationTokenSource` is a level-triggered, tree-structured cancellation scope …
The token governing a computation is carried as a scoped value (`Base.CANCEL_TOKEN` …) that
propagates to child tasks; blocking operations (`wait`, `lock`, Channel operations, `sleep`,
…) accept a `cancel` keyword … and throw a `Base.CancellationRequest` … cleanup code …
shields itself with `cancel = nothing` (or by scoping `Base.CANCEL_TOKEN => nothing`) …
Compute-bound code can opt into cancellation with the `Base.@cancel_check` cancellation point."
Also: "`@sync`, `Threads.@threads` and `Experimental.@sync` blocks now scope a cancellation
source over their children". Severities: `CANCEL_REQUEST_SAFE`, `_ABANDON_EXTERNAL`,
`_ABANDON_ALL`. Merged PRs: #62429 "cancellation: Add basic CancellationToken[Source] APIs"
(2026-07-24), #62655 "Hook up ^C" (2026-08-08); umbrella #60281 closed unmerged.
Source: `gh api repos/JuliaLang/julia/contents/NEWS.md`, `.../base/cancellation.jl?ref=release-1.14`,
`.../pulls/62429`, `.../pulls/62655`, 2026-10-20. Copy at `master_cancellation.jl` in the scratch dir.
Not run: no 1.14 binary installed (UNVERIFIED by execution; API could change before 1.14.0).

### EFF-03 `schedule(t, exc; error=true)` wakes a task parked in any Base wait
Claim: on both versions, injecting an exception into a task blocked in `sleep`,
`take!(::Channel)`, `wait(::Condition)`, `wait(::Base.Event)`, `fetch(other_task)` or
`wait(::Threads.Condition)` ends it at once with that exception.
Source: `run.sh {release,lts} 02_interrupt.jl <case>`.
```
1.13.2 and 1.10.12 (identical lines):
sleep(10)               fetch threw TaskFailedException; t.exception = MyCancel; e.task.exception === t.exception: true
take!(Channel)          ... MyCancel ... true
wait(Condition)         ... MyCancel ... true
wait(Event)             ... MyCancel ... true
fetch(other task)       ... MyCancel ... true
wait(Threads.Condition) ... MyCancel ... true
```

### EFF-04 Injecting into a *running* task corrupts the runtime (do not do it)
Claim: `schedule(t, exc; error=true)` on a task spinning in a loop with no yield point
returns without error but does not interrupt it. When the loop later ends, 1.13.2 aborts the
process ("fatal: error thrown and no exception handler available") and 1.10.12 hangs the
whole process (watchdog kill after 30 s). Base's own `schedule` docstring warns: "It is
incorrect to use `schedule` on an arbitrary `Task` that has already been started."
Source: `run.sh {release,lts} 02_interrupt.jl cpu`; `share/julia/base/task.jl:1041` (1.13.2).
```
1.13.2: cpu: state before schedule = runnable
        cpu: schedule(t, exc; error=true) on a RUNNING task returned without error
        cpu: after 0.5s istaskdone = false
        cpu: after stop flag istaskdone = true state = failed
        fatal: error thrown and no exception handler available.
1.10.12: cpu: state before schedule = runnable
         cpu: schedule(t, exc; error=true) on a RUNNING task returned without error
         WATCHDOG: killed after 30s (hang)
```
So `throwto` is only usable on a task known to be parked, and the canceller cannot know
that without racing. It is not a basis for cancellation.

### EFF-05 `fetch`/`wait` wrap failures in `TaskFailedException`; the original is recoverable
Claim: `fetch`/`wait` on a failed task throw `TaskFailedException`; `e.task.exception` is the
original object (`===` `t.exception`); `current_exceptions(t)` has the stack; `finally`
blocks of an interrupted parked task run.
Source: `run.sh {release,lts} 02_interrupt.jl unwrap`.
```
both: fetch(error task) threw: TaskFailedException
      e.task.exception: ErrorException("original boom")
      t.exception === e.task.exception: true
      length(current_exceptions(t)): 1
      wait(error task) threw: TaskFailedException
      istaskfailed(t2) = true
      finally ran in interrupted task: true
```
Consequence for adapters: Task→effect must catch `TaskFailedException` and fail with
`e.task.exception`; effect→Task must make the task's *body* throw the original so that
callers who unwrap find it (they will still see `TaskFailedException` from `fetch`, which
Julia always adds).

### EFF-06 Safe ways to wake a waiter: through the object it waits on
Claim (both versions): `notify(c, exc; error=true)` fails the waiters of a condition with
`exc`; `close(ch, exc)` makes a blocked `take!` throw `exc` (plain `close(ch)` gives
`InvalidStateException`; a closed buffered channel still yields its items to `collect`); a CPU
loop that polls an atomic flag every 1024 iterations stops promptly; a `Channel(f)` producer's
exception reaches the consumer as `TaskFailedException`.
Source: `run.sh {release,lts} 09_safe.jl`.
```
both: (a) throwto into sleep(0.3): state = failed; no stray error after timer deadline
      (b) notify(c, exc; error=true) -> waiter failed with Cancelled
      (c) close(ch, exc) -> take! threw Cancelled
      (c') close(ch) -> take! threw InvalidStateException
      (c'') iterate closed buffered channel collects: [1]
      (d) polled token in CPU loop -> Cancelled
      (e) collect(Channel(f)) where f throws -> TaskFailedException wrapping ErrorException("producer boom")
```

### EFF-07 `@sync`: waits for all children, but leaks them if the body throws
Claim: when a child fails, `@sync` still waits for every child (no sibling cancellation) and
then throws one `CompositeException` of `TaskFailedException`s. When the `@sync` body itself
throws, `@sync` rethrows at once and does not wait: the child keeps running after the block.
Source: `run.sh {release,lts} 03_sync.jl`.
```
1.13.2: A fails at 0.26 | C finished at 0.66 | B finished at 1.16
        @sync threw CompositeException at 1.16 with 2 exceptions: A boom | C boom
        @sync threw ErrorException at 0.01
        child still ran to completion at 0.67
1.10.12: A fails at 0.26 | C finished at 0.68 | B finished at 1.16
         @sync threw CompositeException at 1.19 with 2 exceptions: A boom | C boom
         @sync threw ErrorException at 0.0
         child still ran to completion at 0.64
```

### EFF-08 `Base.Experimental.@sync` fails fast but does not cancel siblings
Claim: it throws on the first failure (as `TaskFailedException`), and the sibling runs on.
Its docstring: "It is the responsibility of the user to cancel any still-running operations".
`wait_with_timeout` exists on 1.13 only among the run versions.
Source: `run.sh {release,1.11.7,lts} 08_expsync.jl`; `share/julia/base/experimental.jl` (1.13.2, line ~90).
```
1.13.2: Experimental.@sync threw TaskFailedException after 0.19s; sibling done yet: false
        sibling ran to completion afterwards (not cancelled): true
        Experimental.wait_with_timeout(c; timeout=0.1) = timed_out
1.11.7: ... after 0.27s; sibling done yet: false / ran to completion: true / wait_with_timeout: not defined
1.10.12: ... after 0.16s; sibling done yet: false / ran to completion: true / wait_with_timeout: not defined
```

### EFF-09 Scoped values propagate into child tasks on both versions
Claim: a value set with `with`/`@with` is seen in `Threads.@spawn`, `@async`, nested spawns,
`Channel(f; spawn=true)`, `Task(f)` built inside the scope, and `Timer` callbacks. A task
*constructed* outside and scheduled inside sees the creator's scope (scope is captured at
construction).
Source: `run.sh {release,lts} 04_scoped.jl` (1.13: `Base.ScopedValues`; 1.10: ScopedValues.jl 1.6.2).
```
both: outside: root | inside with: inner | Threads.@spawn child: inner | @async child: inner
      nested spawn: inner | Channel(f; spawn=true) task: inner | Task(f) constructed inside with: inner
      Task created outside, scheduled inside with: root | @with: macro | Timer callback: timer
```

### EFF-10 ScopedValues.jl 1.6.2: tiny, Julia ≥ 1.8, re-exports Base on 1.11+
Claim: latest registered ScopedValues is 1.6.2 (11 versions); compat `julia = "1.8.0 - 1"`;
deps `HashArrayMappedTries` (0.2) and `Logging`. On Julia with `Base.ScopedValues` it does
`import Base.ScopedValues: ScopedValue, with, @with, Scope, get`, so the types are identical.
Repo JuliaLang/ScopedValues.jl, last push 2026-04-28.
Source: registry `S/ScopedValues/{Versions,Compat,Deps}.toml`;
`~/.julia/packages/ScopedValues/sILa0/{Project.toml,src/ScopedValues.jl}` lines 1–8; run on 1.13.2:
```
ScopedValues.ScopedValue === Base.ScopedValues.ScopedValue: true
```
OhMyThreads 0.8 already depends on ScopedValues (registry `O/OhMyThreads/Deps.toml`).

### EFF-11 `timeout` can be built from `Timer` + `Base.Event`; the loser must be stopped somehow
Claim: racing a work task against `Timer(_ -> notify(done), secs)` works on both versions;
`timedwait(f, secs)` returns `:ok`/`:timed_out`; `Base.Event(true)` (autoreset) exists on both.
The demo stops the loser with `throwto`, which is only safe because it is parked in `sleep`
(EFF-04); a real runtime must deliver cancellation through a token instead.
Source: `run.sh {release,lts} 05_timeout.jl`.
```
1.13.2: fast work: (:ok, 42) | slow work: (:timed_out, TimeoutCancel) after 0.34s; finally ran: true
        timedwait(false, 0.2) = timed_out in 0.23s | timedwait(true, 0.2) = ok
        Event(autoreset=true) available; after one wait isset: false
1.10.12: fast work: (:ok, 42) | slow work: (:timed_out, TimeoutCancel) after 0.32s; finally ran: true
         timedwait(false, 0.2) = timed_out in 0.22s | Event(autoreset=true) available
```

### EFF-12 Cost: a task hop is about 500× an interpreted bind step
Claim: one interpreted `flatMap` step of a minimal effect ADT (abstract node types, trampoline
with an explicit stack) costs ~25–60 ns; `fetch(Threads.@spawn 1)` costs ~10–20 µs median
under this load (minimum can drop to 0.5 µs when the task runs on the spawning thread).
Running every bind as its own Task is therefore out; running the interpreter inside a Task
and spawning only on `fork` is cheap.
Source: `06_bench.jl`, evidence files `.lanes/evidence/eff-bench-113-db74452.txt` and
`.lanes/evidence/eff-bench-110-db74452.txt` (`julia scripts/evidence.jl eff-bench-11x -- julia +<ch> --startup-file=no -t 4 --project=<env> 06_bench.jl`).
```
                                   1.13.2            1.10.12
plain call inc(1)                  1.87 ns           1.42 ns
plain loop 1000 (dynamic dispatch) 10.96 us          9.58 us
run_eff(prebuilt 1000 flatMaps)    24.9 us (med 29)  27.8 us (med 59.8)
build+run 1000 flatMaps            27.3 us           30.5 us
fetch(Threads.@spawn 1) min        10.2 us           0.54 us
spawn+fetch median                 14.6 us           19.0 us
1000 sequential spawn+fetch        15.1 ms           28.8 ms
allocs: spawn+fetch 4 (320 B / 480 B); run_eff 1000: ~1500 allocs, 43–46 KB
```

### EFF-13 Julia packages in General (registry snapshot 2026-10-20)
| Package (latest) | What it is (verified by source/README/description) | julia compat | Deps | Last push |
|---|---|---|---|---|
| CancellationTokens 2.3.0 | .NET-style `CancellationTokenSource`/`CancellationToken`, `cancel`, `register`, `OperationCanceledException`; adds `sleep(s, token)`, `wait(token)`, timeout and linked sources | `1` | Sockets | 2026-09-17 |
| ConcurrentUtilities 2.7.1 | `Lockable`, `OrderedSynchronizer`, `ReadWriteLock`, `Pool`, `Worker`, `try_with_timeout` | `1.6.0 - 1` | Serialization, Sockets | 2026-10-16 |
| ScopedValues 1.6.2 | backport of `Base.ScopedValues` (EFF-10) | `1.8.0 - 1` | HashArrayMappedTries, Logging | 2026-04-28 |
| ExtensibleEffects 1.1.1 | extensible-effects (Eff monad) encoding; not a runtime | `1.6.0-1` | Compat, DataTypesBasic, Distributed, ExprParsers, Monadic, Reexport, TypeClasses | 2026-03-14 |
| Dagger 0.22.7 | DAG scheduler for parallel/out-of-core work | `1.10.0 - 1` (last section) | many (Distributed, MemPool, TaskLocalValues, …) | 2026-10-18 |
| Actors 0.2.5 | actor model | `1.6.0-1` | Serialization, … | 2021-10-01 |
| ResumableFunctions 1.0.8 | C#-style generators (semi-coroutines) via macro state machines | `1.10.0 - 1` | Logging, … | 2026-10-04 |
| Continuables 1.0.3 | callback-based generator alternative to Channels | `1` | Compat | 2023-07-01 |
| OhMyThreads 0.8.7 | task-based multithreading helpers | `1.10.0 - 1` | ScopedValues, … | 2026-10-02 |
| ContextVariablesX 0.1.3 | older context-variable package (pre-ScopedValues) | `1` | Compat, Logging, UUIDs | 2022-10-06 |
| ConcurrentUtils 0.1.0 | single-release concurrency primitives | `1.6.0-1` | Try, UnsafeAtomics, … | 2024-07-30 |

Name collisions, not related: `Effects` (beacon-biosignals: regression effects), `Fibers`
(fibre imaging), `Retry` 0.4.1 (JuliaWeb retry macro), `Promises` 0.1.0 (Pluto, julia 1.6–1.7).
No registered package named StructuredConcurrency, Nurseries, FutureWorkers or a ZIO-style
effect runtime was found (`grep` of `Registry.toml` for those names: no hits).
Source: `gzip -dc ~/.julia/registries/General.tar.gz | tar -O -x -f - Registry.toml | grep …`
and the per-package `Versions/Compat/Deps.toml`; `gh api repos/<repo>` for push dates.

### EFF-14 Existing Julia cancellation helpers are cooperative only
Claim: CancellationTokens' `sleep(10, token)` returns early with `OperationCanceledException`
when cancelled; linked/timeout sources work. ConcurrentUtilities' `try_with_timeout` throws
`TimeoutException` but leaves the work task running (it only passes a `TimedOut` flag), and
wraps errors in `CapturedException` (not the original).
Source: `run.sh {release,lts} 07_prior.jl`;
`~/.julia/packages/ConcurrentUtilities/nHnHy/src/try_with_timeout.jl` (2.7.1).
```
both (CancellationTokens 2.3.0; ConcurrentUtilities 2.7.1):
sleep(10, token) after cancel at 0.1s -> canceled in 0.17s (1.13) / 0.15s (1.10)
linked timeout source fired after 0.05s
try_with_timeout result: TimeoutException
work kept running to completion after the timeout: true
try_with_timeout on error rethrows: CapturedException
```

## Prior art, other languages

### EFF-15 ZIO 2 (Context7 `/websites/zio_dev`, zio.dev reference, read 2026-10-20)
- Interruption is asynchronous: "fibers can be terminated directly without requiring manual
  polling"; critical sections disable interruptibility (`ZIO.uninterruptible`,
  `uninterruptibleMask(restore => …)`; a forked child inherits uninterruptibility).
- Children are scoped to parents: "When a parent fiber finishes its execution, whether
  successfully or through interruption, all child fibers spawned by it are automatically
  interrupted." Escapes: `forkDaemon` (global scope), `forkScoped` (a local `Scope`).
- `acquireRelease(acquire)(release): ZIO[R with Scope, E, A]`; acquire and release are
  uninterruptible; finalizers run in reverse registration order (LIFO).
- `timeout` returns `Option`; the timed-out effect is interrupted, unless uninterruptible, in
  which case `timeout` waits for it. `Schedule` values (e.g. `Schedule.exponential(10.millis)`)
  drive `retry`/`repeat`.

### EFF-16 cats-effect 3 (Context7 `/typelevel/cats-effect`, series/3.x docs)
- Outcome of a fiber: `Succeeded`, `Errored`, `Canceled`.
- Cancellation is checked "at every step of execution", like checking the interrupt flag "on
  every semicolon", so infinite pure loops are cancellable. It is cooperative in that "a
  canceling fiber waits if the target fiber cannot cancel immediately, and the target fiber
  runs finalizers" (cancel back-pressures until finalizers finish).
- Masking: `IO.uncancelable(poll => …)`; `poll` restores cancelability only to the enclosing
  level (nested-mask example in `monadcancel.md`).
- `bracket`: release always runs (success, error, cancel); acquire is atomic. `Resource`
  releases in reverse acquisition order; acquire/release are non-interruptible.
- `parTraverse`: one failure cancels the others.

### EFF-17 Kotlin coroutines (Context7 `/websites/kotlinlang_api_kotlinx_coroutines`)
- Cancellation is cooperative: "Only the next suspension point will observe the cancellation"
  (or an `isActive` check). It is delivered as `CancellationException`, which does not count as
  a failure for the parent.
- In `coroutineScope`, a child failing with a non-cancellation exception cancels the scope and
  its other children; `SupervisorJob` opts out.
- `withTimeout` raises `TimeoutCancellationException`; cleanup that must suspend uses
  `withContext(NonCancellable)` in `finally`.

### EFF-18 Trio / AnyIO (Context7 `/python-trio/trio`, `/agronholm/anyio`)
- A nursery waits for all children; if one raises, "the nursery cancels all other tasks and
  re-raises the exceptions grouped together".
- Cancel scopes are stateful and *level-triggered*: while a scope is effectively cancelled,
  every yield point raises again (AnyIO contrasts this with asyncio's edge cancellation).
  Shielding: `CancelScope(shield=True)` / `move_on_after(t, shield=True)` for cleanup.
  `move_on_after` (silent) vs `fail_after` (raises). The timeout scope must enclose the nursery.

### EFF-19 Fluture 14.0.0 (github.com/fluture-js/Fluture README)
Futures are lazy; a computation "must return a nullary function containing cancellation
logic"; `fork` returns an unsubscribe function; in `hook` (bracket), cancellation after
acquisition still runs disposal; `race`: "When one Future settles, the other gets cancelled".

### EFF-20 Folktale Task (origamitower/folktale master, `_task.js` and `task.js`)
The resolver has `cancel`, `cleanup`, `onCancelled`, `isCancelled`. `run()` returns an
execution; on cancel, cancellation handlers run, then cleanups; on settle, only cleanups.
`or` cancels the other execution when one settles. Chained tasks forward cancel to the
running stage.

## Synthesis: delivery, masking, finalizers, children

| System | Delivery | Masking | Finalizers | Parent cancelled/fails → child |
|---|---|---|---|---|
| ZIO 2 | async, between instructions | `uninterruptible`, `uninterruptibleMask` | LIFO, release uninterruptible | interrupted (unless daemon/scoped) |
| cats-effect 3 | checked every step; waits for finalizers | `uncancelable(poll)` | LIFO, release uncancelable | cancelled (`parTraverse`, `race`) |
| Kotlin | cooperative at suspension points | `NonCancellable` | `finally` | cancelled; child failure cancels siblings |
| Trio/AnyIO | level-triggered at checkpoints | `shield=True` | `finally` + shield | cancelled, errors grouped |
| Fluture/Folktale | cancel callback per computation | none | `hook`/cleanup | race loser cancelled |
| Julia ≤1.13 | none (only unsafe `throwto`, EFF-04) | none | `finally` | `@sync`: not cancelled; body-throw leaks (EFF-07) |
| Julia 1.14 | token, level-triggered, scoped value (EFF-02) | `CANCEL_TOKEN => nothing` | `finally` | `@sync` scopes a source over children |

## Recommendation

1. **Run on Julia `Task`s; no own scheduler.** An effect is a data structure (ADT) run by a
   trampolined interpreter inside the current Task; `fork`/`zipPar`/`race` spawn Tasks
   (`Threads.@spawn`). Interpreting a bind costs ~25–60 ns, a Task hop ~15 µs median (EFF-12),
   so do not spawn per step. Tasks already carry scoped values (EFF-09) and integrate with Base
   I/O, `Channel` and `Timer` (EFF-06, EFF-11). A custom fiber scheduler would duplicate Base
   and could not preempt CPU loops either.
2. **Cancellation: a cooperative, level-triggered token carried in a `ScopedValue`.** Follow
   Trio/AnyIO and the Julia 1.14 design (EFF-02, EFF-18). (a) The interpreter checks the token
   between every step (the cats-effect model, EFF-16), so pure effect loops cancel. (b) Our own
   blocking primitives (sleep, await, take, acquire) wait on "work done OR token cancelled" and
   are woken through the waited-on object (`notify(c, exc; error=true)`, `close(ch, exc)`,
   closing the Timer; EFF-06). (c) **Never** use `schedule(t, exc; error=true)`/`throwto` to
   cancel; it corrupts a running task (EFF-04). (d) Opaque Julia code (CPU loops, foreign
   `fetch`) is uncancellable until it returns; document it, and offer a `checkcancel()` helper
   for loops. (e) Masking: `uninterruptible(eff)` and `interruptibleMask(restore -> …)` are
   implemented by scoping the token to "none" (shield) and restoring it, which is exactly
   Base 1.14's `CANCEL_TOKEN => nothing`. (f) Outcome is three-way: Success / Failure(cause) /
   Cancelled (EFF-16). Cancelling a fiber waits for its finalizers (back-pressure, EFF-16).
   (g) Keep a seam for Base 1.14+: our token type should wrap or forward to
   `Base.CancellationTokenSource` when `isdefined(Base, :CancellationTokenSource)`, so Base
   blocking calls (which will honour `Base.CANCEL_TOKEN`) cancel too. This needs an ADR and
   a re-check against 1.14.0 final (EFF-02 is alpha, not run).
3. **Structured concurrency and finalizers.** Every fork belongs to a scope. On scope exit the
   scope waits for all children. A child failure cancels its siblings, then rethrows the
   *original* first exception (others kept as a composite/suppressed list). Parent
   cancellation cancels children. This deliberately differs from `@sync`, which neither
   cancels siblings nor waits when the body throws (EFF-07, EFF-08). `Scope`/`acquireRelease`
   finalizers run LIFO, each under a shield, all run even if one throws, and release receives
   the exit outcome (ZIO/cats-effect, EFF-15, EFF-16). `timeout` = race against a `Timer`, with
   the loser cancelled through its token and awaited (ZIO semantics: an uninterruptible effect
   delays the timeout result, EFF-15).
4. **Adapters** (per the brief). Task→effect fails with `e.task.exception`, not
   `TaskFailedException` (EFF-05). Effect→Task throws the original from the task body.
   Cancelling the effect cancels the token the task runs under (not `throwto`). Channel close
   ends a stream, and `close(ch, exc)` fails it (EFF-06).
5. **Dependencies.** Add **ScopedValues.jl** only (`ScopedValues = "1.6"`): it works on 1.10,
   is the identical `Base` type on 1.11+ (EFF-10), and its only deps are HashArrayMappedTries and
   Logging. No Compat is needed for anything above (Event, Timer, `timedwait`, `notify(...;
   error=true)` and `close(ch, exc)` all ran on 1.10, EFF-06/EFF-11). Do not depend on
   CancellationTokens.jl (separate token world, not scoped, no Base 1.14 bridge) or
   ConcurrentUtilities (its timeout does not stop work and hides the original error, EFF-14).
   Borrow their designs (linked sources, timer sources) instead.

## UNVERIFIED

- Julia 1.14 cancellation behaviour at run time (source/NEWS only; alpha1, could change).
- Julia 1.12 behaviour (source grep only; the local 1.12.5 install has no binary).
- Whether Dagger.jl exposes task cancellation (not checked).
- ZIO's exact interruption check granularity in the 2.x runtime (the docs say "asynchronous";
  the per-instruction detail was not checked in source).
- Folktale: whether cancelling a linked (chained) execution cancels its successor
  (`_task-execution.js` not read).
- Benchmark absolute values on an idle machine (all runs were under load average 37–62).

## Also noticed

- On Julia 1.10.12 `Sys.CPU_THREADS` printed 6, while 1.13.2 printed 12 on the same machine
  (evidence files). Do not use it to size pools without checking.
- CancellationTokens.jl adds methods to `Base.sleep`/`Base.wait` for its own token type.
