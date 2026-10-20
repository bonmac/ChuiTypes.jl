# Phase 3 design: Reader/Writer/State, the effect runtime and its adapters

- **Lane:** `phase3-effects`, branch `feat/phase3-effects`, from `main` at `dc1882c`.
- **Tier:** T2 (public API, a new dependency). Binding inputs: ADR-0001 (as amended), ADR-0002,
  ADR-0005, ADR-0006, ADR-0007 (Proposed, this phase), ecosystem ADR-0013.
- **Scope:** the decisions those ADRs leave open. Where this spec and an ADR disagree, the ADR
  wins and this spec is wrong.
- **Out of scope (phase 4):** streams, `Queue`, `fromchannel`/`tochannel`, futures, semaphores.

## 1. Names proposed at the phase-3 ★

User-accepted already: `Effect{E,A}` (no environment parameter), `run` as a `Base.run` method,
`interrupt!` + `await`, no type named `IO`, `Task` or `Future`.

Proposed here (CT-003 checks every export against Base, Core and the loaded stdlibs):

| Group | Exported | Public, not exported |
|---|---|---|
| Reader/Writer/State | `Reader`, `Writer`, `State`, `ask`, `asks`, `withreader`, `tell`, `listening`, `censor`, `getstate`, `putstate`, `modifystate`, `runreader`, `runwriter`, `runstate` | `ReaderTag`, `WriterTag`, `StateTag` |
| Effect values | `Effect`, `succeed`, `fail`, `die`, `sync`, `attempt`, `defer`, `andthen` | `fromexit` |
| Outcomes | `Exit`, `Cause`, `runexit`, `EffectFailed`, `Cancelled`, `MissingService` | `Success`, `Failure`, `Fail`, `Die`, `Interrupted`, `succeeded` (not `issuccess`, which LinearAlgebra exports), `isfail`, `isdie`, `isinterrupted`, `cause`, `value`, `suppressed` |
| Errors | `catchfail`, `catchcause`, `mapfail` | |
| Environment | `provide`, `service` | |
| Cancellation | `checkcancel`, `uninterruptible`, `interruptiblemask`, `interrupt!`, `await` | |
| Concurrency | `Fiber`, `fork`, `start`, `scope`, `race`, `racefirst`, `timeout`, `timeoutfail`, `zippar` | |
| Resources | `bracket`, `acquirerelease`, `ensuring` | |
| Clock | `delay`, `clocktime`, `VirtualClock`, `advance!`, `runtest` | `RealClock`, `AbstractClock` |
| Schedules | `retry` (a `Base.retry` method), `recurs`, `spaced`, `exponential` | `Schedule` |
| Adapters | `async`, `fromtask`, `totask` | |
| Counters | | `livefibers`, `orphans` |

`andthen(k, m)` is the public bind for `Effect`, `Reader`, `Writer` and `State` (the
`Upstream.chain` stand-in is not public, ADR-0004). `jittered` (ADR-0002 §9) is deferred: it needs
a random source, and `Random` is not a dependency (ADR-0005).

## 2. Reader/Writer/State (ADR-0007)

- Values: `Reader{R}`, `Writer{W}`, `State{S}`, each one field holding an internal tagged node.
- Constructors that need the parameter take it: `ask(R)`, `asks(f, R)`, `getstate(S)`,
  `putstate(S, x)` (stores `convert(S, x)`; `putstate(x)` means `putstate(typeof(x), x)`),
  `modifystate(f, S)`, `tell(w)` (gives `Writer{typeof(w)}`; `tell(W, w)` converts),
  `Upstream.pure(ReaderTag{R}(), x)` and the like.
- `andthen(k, m::State{S})`: `k` must return a `State{S}`; any other value throws an
  `ArgumentError` naming both types, at run time. Same for Reader and Writer.
- `withreader(f, m::Reader{R})` runs `m` with environment `f(r)` (Reader's `local`);
  `listening(m::Writer{W})` gives `(a, w)` where `w` is the log `m` wrote (also kept in the outer
  log); `censor(f, m)` replaces `m`'s log with `f(log)`. All three push a restore frame onto the
  explicit stack, so nesting them 10^5 deep is stack-safe (tested).
- Run: `runreader(m, r[, T])`, `runstate(m, s0[, T]) -> (a, s)`,
  `runwriter(m, mon[, T]) -> (a, w)`. With `T`, `a::T` is asserted. Writer starts from
  `neutral(mon)` (once per run, fresh) and threads `acc = combine(mon, acc, w)` in execution
  order, so left- and right-nested chains give the same log even before associativity is used.
  The accumulator is owned by the run: an in-place monoid gives linear cost, a copying one is
  quadratic (`rws-113`: 27 ns vs 987 ns per tell at 10^4).
- `Base.map(f, m)`, `Upstream.fmap/pure/ap/chain`. No `==` (extensional equality, ADR-0007 §5).
- Immutable values: safe to share across threads; each run allocates its own stack.

## 3. Effect values and outcomes (ADR-0002 §1, §3)

- `Effect{E,A}` is a struct with one field, an internal tagged node (`_ENode(tag, a, b, c)`,
  untyped payloads). `E` and `A` are **advisory**: computed at construction (`succeed(x)` gives
  `Effect{Union{},typeof(x)}`, `fail(e)` `Effect{typeof(e),Union{}}`, `map` and `andthen` use
  `promote_op` with ADR-0001 §4's extraction rule, falling back to `Any`), and never asserted.
  `run(eff, T)` asserts `T`.
- `Cause{E}`: a concrete struct `(tag, e::Union{Nothing,E}, ex, bt, suppressed::Vector{Cause})`.
  Constructors `Fail(e)`, `Die(ex, bt)` (`Cause{Union{}}`), `Interrupted()`. `suppressed` holds the
  causes a scope or `race` dropped (§6) and the failures of later finalizers (§7).
- `Exit{E,A}`: `Success(a)` gives `Exit{Union{},typeof(a)}`, `Failure(c::Cause{E})` gives
  `Exit{E,Union{}}`. Parameters come from the values, so they are never stale.
- `run(eff)` / `run(eff, T)`: run in the calling task as the root fiber; return the value or
  throw per ADR-0002 §3. `runexit(eff)` returns the `Exit`.
- `sync(f)`: calls `f()`; a throw is `Die(ex, bt)`, except that a `Cancelled()` thrown while the
  fiber is cancelled is `Interrupted` (that is how `checkcancel()` stops a `sync`). `attempt(f)`:
  a throw is `Fail(ex)`, with `EffectFailed(e)` → `Fail(e)` and `Cancelled()` → `Interrupted`
  (ADR-0006 §4). `defer(f)`: `f()` returns an effect, run in its place (recursion).
- `run` inside a `sync` (a nested run) runs under the ambient fiber: the same cancel state, a
  child scope, the same environment. That is how `fromtask(f::Function)` thunks reach the runtime.

## 4. The interpreter

- One loop per fiber, with an explicit frame stack: bind, map, catch (fail / cause), restore
  (environment, mask, cancel state), finalizer (release with the `Exit`), scope exit.
- **Fiber context** (interpreter-local, ADR-0002 §4): the current cancel state, the environment,
  the mask depth, the current scope, the runtime mode (real or test). It is bridged into one
  `ScopedValue` (`ScopedValues.ScopedValue`, ADR-0005) once around each `sync`/`attempt` call and
  each spawn, never per step.
- **Failure unwinding:** a failure pops frames: binds and maps are skipped; a matching catch frame
  runs its handler (catch frames never see `Interrupted`); restore frames are applied; finalizer
  frames run their release masked with the `Exit` (§7); scope frames run their exit (§6).
- **Cancellation check:** between steps, when the cancel state is set and the mask depth is 0, the
  fiber fails with `Interrupted` and unwinds. While unwinding with `Interrupted`, no further check.
- **Masking:** `uninterruptible(eff)` raises the mask depth for `eff`.
  `interruptiblemask(restore -> eff)` runs masked and passes `restore`, which runs its argument at
  the mask depth outside the call. A primitive started while masked waits without cancellation.

## 5. Cancel states and waiting (ADR-0002 §4, §5)

- A **cancel state** is a mutable reference with a flag, a lock, a parent and a set of children
  and parked waiters. `cancel!(cs)` sets the flag on `cs` and every descendant and wakes their
  waiters. A check reads one flag (level-triggered).
- **Waiter:** a one-shot `(fired, Threads.Condition)`. Every runtime primitive (`delay`, `await`,
  `async`, scope joins) parks on a waiter that is woken by its source **or** by a cancel of the
  current cancel state when unmasked. Parking and waking go through the runtime so test mode can
  count them.
- `interrupt!(f)` cancels the fiber's cancel state (signal only). `await(f)` is an effect giving
  the fiber's `Exit`; it is cancellable. `fromexit(x)` replays an `Exit`. `Base.fetch(f)` and
  `Base.wait(f)` block the calling task (not cancellable).

## 6. Scopes and fibers (ADR-0002 §2, §6)

- `scope(eff)` runs `eff` under a new cancel state (a child of the current one) and a new
  `Scope`. Every fiber's body, and every `run`, is wrapped in a scope.
- `fork(eff)` gives a `Fiber` in the innermost scope; its cancel state is a child of the scope's.
  Its mask depth starts at 0. Real mode: `Threads.@spawn`; test mode: `@async` (sticky).
- **Exit of a scope.** Body succeeded: wait for every child, cancellably. Body failed or was
  interrupted, or the wait was interrupted: cancel the scope's cancel state, then wait for every
  child **masked**.
- **Supervision.** The first child that ends with `Fail` or `Die` records its cause and cancels the
  scope (body and siblings). The scope then fails with that cause; later child failures and the
  body's own `Interrupted` go to `suppressed`, or are dropped when the scope caused them.
  `Interrupted` children never fail a scope. A child failure fails the scope **even if the parent
  awaited it** (Kotlin semantics); `race`, `timeout` and `zippar` use internal unsupervised
  children, whose failures only reach the awaiter.
- `start(eff; clock = nothing)`: runs `eff` as a new root fiber in its own task (test mode when
  `clock isa VirtualClock`) and returns its `Fiber`.

## 7. Resources (ADR-0002 §7)

- `bracket(acquire, use, release)`: `acquire` runs masked; then a finalizer frame is pushed, `use(a)`
  runs, and `release(a, exit)` runs masked with `use`'s `Exit`. `acquirerelease(acquire, release)`
  is `bracket` whose use is `succeed`. `ensuring(eff, fin)` runs `fin` (an effect) masked after
  `eff` however it ends.
- Nested brackets release LIFO (stack order). Every release runs even when an earlier one fails;
  the first failure is the cause, later ones go to `suppressed`. A release failure after a
  successful `use` fails the bracket.

## 8. Racing, timeouts, parallel (ADR-0002 §8)

- `race(a, b)`: first success wins; the loser is interrupted and awaited; both failing gives the
  first cause with the second in `suppressed`. `racefirst(a, b)`: first outcome, loser interrupted
  and awaited. `zippar(a, b)`: both in parallel, `(x, y)`; the first failure interrupts the other.
- `timeout(eff, d)::Effect{E,Option{A}}`: `some(x)` or `none(A)` (advisory `A`);
  `timeoutfail(eff, d, e)` fails with `Fail(e)` on expiry.

## 9. Clock and test mode (ADR-0002 §9, §10)

- `AbstractClock`; `RealClock()` is the default service; `VirtualClock()` starts at time `0.0`.
  Times and durations are `Float64` seconds (no `Dates` dependency). `delay(d)`, `clocktime()`.
  `provide(eff, services...)` keys each service by its type; `service(S)` returns the innermost
  `v isa S`, or dies with `MissingService(S)`.
- **Test mode** is selected by `runtest(eff; clock = VirtualClock(), timeout = 10.0)` or
  `start(eff; clock = vc)`. All fibers and `fromtask` thunks are sticky `@async` tasks on the
  caller's thread. The clock counts live and parked fibers.
- `advance!(clock, d)` (called from a task on the same thread): wait for quiescence (live ==
  parked); then fire due timers one at a time in `(due, sequence)` order, setting the time to each
  due time and waiting for quiescence after each; finally set the time to `now + d` and wait for
  quiescence. A wall-clock `timeout` (seconds) throws an `ErrorException` naming the fibers still
  running.
- `runtest(eff)` runs `eff` as a test-mode root fiber and, whenever it is quiescent and not done,
  advances to the next due timer; with no timer due and no progress it throws (deadlock).

## 10. Adapters (ADR-0006)

- `async(register; grace = nothing)`: as ADR-0006 §1. `cb` is an idempotent, thread-safe
  one-shot (atomic first-wins). On cancellation: call the canceller (if any), then wait for `cb`
  masked; with `grace = d`, give up after `d` (real time in real mode, clock time in test mode),
  increment `orphans()` and end `Interrupted`.
- `fromtask(t::Task; canceller = nothing)`: schedules `t` if not started, awaits it once (Base
  caches the outcome); failure is `Fail(t.exception)`, unwrapping `EffectFailed` and `Cancelled`
  (ADR-0006 §4). On cancellation: with a canceller, call it, then await `t` masked; without one,
  end `Interrupted` at once and increment `orphans()`.
- `fromtask(f::Function)`: spawns `f` under the fiber's context (a child cancel state), awaits it,
  and on cancellation cancels that child state and awaits the work.
- `totask(eff)::Task`: a started root fiber's task; `fetch` throws `TaskFailedException` with
  `task.exception === original`.

## 11. Retry and schedules (ADR-0002 §9, PROVISIONAL)

- `Schedule` holds `next(n) -> Union{Nothing,Float64}`: the delay before retry `n` (1-based), or
  `nothing` to stop. `recurs(n)`, `spaced(d)`, `exponential(base; factor = 2.0)`, and
  `recurs(n, s)` to bound another schedule. `retry(eff, s)` reruns `eff` on `Fail` (not on `Die`
  or `Interrupted`), delaying through the clock.

## 12. Counters and leaks (ADR-0002 §11)

- `livefibers()` counts fibers started and not finished; `orphans()` counts abandoned tasks and
  given-up `async` callbacks. Stress tests assert `livefibers()` returns to its baseline.
- An `InterruptException` reaching the root fiber's interpreter cancels the root scope and is
  rethrown by `run` after the best-effort unwinding.

## 13. Tests

- Laws: Functor/Applicative/Monad for `Reader`, `Writer`, `State` and `Effect` through the local
  kits, with `eq` running both sides on sample inputs (`run`/`runexit` for `Effect`).
- Properties (`@check record=false db=false` plus `@test`): every finalizer runs exactly once and
  LIFO under cancellation at a random step; scopes leave no live fiber; the Task round trip keeps
  the value, the exception object (`===`) and the cancellation. Each property has a planted
  violation (a deliberately wrong runtime stand-in) that runs on 1.10.
- Stress (`:slow`): thousands of forks, races and timeouts, then `livefibers()` back at baseline.
- Virtual time: deterministic order of same-instant wake-ups, `timeout`, `retry`, `race` timing.
