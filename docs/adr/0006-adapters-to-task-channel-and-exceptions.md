# ADR-0006: Adapters to Task, Channel and exceptions go through owned handles and cancellers

- **Status:** Accepted (2026-10-20, user at the ChuiTypes phase-1 ★). The `chui-types.md`
  obligation-2 amendment (B1/B2, "Consequences" wording) is pending as a contract ADR in the
  coordinator; applying it needs the user's T3 approval.
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint (via the lead); B1/B2 below go to the
  coordinator as a contract ADR
- **Scope:** ChuiTypes.jl

## Context

`contracts/chui-types.md`, obligation 2, puts every conversion between the runtime (ADR-0002) and
`Task`, `Channel`, exceptions, futures and streams in ChuiTypes, with these semantics:
- Task → effect: the task runs once, and a failure lands in the error channel with the task's
  exception.
- Effect → Task: a failure "is thrown from `fetch` as the original exception", and cancelling the
  effect stops the task.
- Channel: `close` ends the stream, and an exception that closes it fails the stream.
- The round trip behaves like the original.

Facts:

- **`fetch` always wraps.** On a Base `Task` it throws `TaskFailedException`, even when the body
  rethrows the original. The original is at `e.task.exception` (EFF-05; `crit-fetch10-*`, both
  versions).
- **A foreign task cannot see our token.** A task captures scoped values when it is constructed
  (EFF-09). A foreign `@task read(io)` therefore sees no ChuiTypes cancel state (`crit-fetch-113`:
  `foreign task sees token: nothing`), and opaque code such as `read` never checks a token.
- **Channel iteration is version-dependent.** Iterating a `Channel` closed with `close(ch, ex)`
  ends silently on 1.10.12 and 1.11.7, and throws on 1.13.2. `take!` throws `ex` on both versions.
  A producer bound with `bind` fails as `TaskFailedException` (STR-13, STR-14).
- **Prior art for cancellers.** Fluture's computation returns a cancel function (EFF-19), Folktale
  has `onCancelled` (EFF-20), and ZIO `async` and cats-effect `IO.async` take finalizers (EFF-15,
  EFF-16).
- **Names.** `Task` and `IO` are Core/Base exports, and `Future` is Distributed's
  (`names-{113,110}`).

## Decision

1. **Canceller primitive.** `async(register; grace = nothing)` creates an effect.
   - `register(cb)` starts outside work. It must later call `cb(exit)`, and it returns a
     **canceller** closure, or `nothing`.
   - **`cb` is thread-safe and idempotent.** It may be called from any thread or `Timer`
     callback, and **the first call wins**: later calls are ignored. A call made before `register`
     returns is valid. The outcome is then already settled, and the canceller is never invoked.
   - **On cancellation** the runtime calls the canceller (for example to close a socket or
     `notify` a condition), then waits for `cb`, masked.
   - **`grace`.** With `grace = nothing` (the default, which favours resource safety), the effect
     waits for `cb` indefinitely. A canceller that never leads to `cb` hangs the effect, and the
     docs say so. With `grace = d`, the runtime gives up after `d`, records an **orphan** (see §2)
     and ends `Interrupted`.
   - Hot sources (ADR-0003) and every adapter below are built on it.
2. **Task → Effect.** `fromtask(t::Task; canceller = nothing)::Effect{Exception,A}`.
   - Running the effect schedules `t` if it is not started yet, and awaits it **once**. Later runs
     see the same outcome, because `fetch` caches it.
   - A failure is `Fail(t.exception)`: the original object, never the `TaskFailedException`. The
     error type is `Exception`, so typed handlers see it.
   - **On cancellation with a canceller:** the canceller runs, then the effect awaits `t`.
   - **On cancellation without a canceller:** the effect ends `Interrupted` at once, and `t` is
     **abandoned**. It is counted in the runtime's orphan counter, and the docs say so.
   - Waiting uninterruptibly instead would make `timeout(fromtask(t), d)` hang (critic B2).
   - **For cancellable work, pass a thunk.** `fromtask(f::Function)` is a separate method. It
     spawns `f` under the fiber's cancel state (as `@async` in test mode), so `checkcancel()` and
     the runtime primitives inside it work. On cancellation it **awaits** the work, because the
     work is cooperative.
3. **Effect → Task / handle.**
   - `fork`/`start(eff)` returns a `Fiber{E,A}`. `fetch(::Fiber)` (a method on the owned type)
     follows ADR-0002 §3: it throws the **original exception** for `Die(ex)` and for
     `Fail(ex::Exception)`, `EffectFailed(e)` only for a non-exception `e`, and `Cancelled()`
     for `Interrupted`. So `fetch(start(fromtask(t)))` and `run(fromtask(t))` throw `t`'s own
     exception, matching the contract's example.
   - `interrupt!(f)` cancels the fiber, and the fiber's task stops at its next step or primitive.
     `await(f)` waits for it.
   - `totask(eff)::Task` exists for Base interop. Its `fetch` throws `TaskFailedException` whose
     `task.exception` is that same original object, because Base cannot do otherwise.
4. **Exceptions.**
   - A thrown exception becomes `Die(ex)`. Converting back rethrows `ex` (`===`).
   - `EffectFailed(e)` and `Cancelled()` are recognised by `fromtask` and by `attempt`, which turn
     them back into `Fail(e)` and `Interrupted`.
   - **Asymmetry, kept on purpose.** An exception that crosses a Task boundary always comes back
     as `Fail(ex)`: a `Die(ex)` that goes out through `totask` or `fetch` returns as `Fail(ex)`,
     because a Base `Task` has no defect/error distinction. The round trip keeps the exception
     object, the success value and the cancellation, but **not the `Die`/`Fail` kind**. This is
     part of contract note C3.
   - An `InterruptException` (^C) reaching the root fiber cancels the root scope, so finalizers
     run **best-effort** (ADR-0002 §11), and `run` then rethrows the `InterruptException`.
5. **Channel ↔ stream.**
   - `fromchannel(ch)` reads with `take!` and never by iteration. `InvalidStateException` on a
     closed channel ends the stream.
   - When the channel is closed with an exception, that exception fails the stream, unwrapped from
     `TaskFailedException` when it comes through `bind`. The internal field `ch.excp` is never
     read.
   - The stream is **hot and single-consumer**. Two runs split the items, as documented.
   - `tochannel(stream; size)` runs the stream in a fiber, puts the chunks' elements and closes
     the channel, with `close(ch, ex)` on failure. Closing the channel from the consumer side
     cancels that fiber.
6. **Futures and the task-like type are thin constructors of `Effect`, not aliases and not
   types.** A Fluture-style lazy future is any `Effect`, cold and cancellable. A Folktale-style task
   is `async` with a canceller. The brief's IO is `Effect{Union{},A}` built with `sync(f)`: it
   has no typed error, and anything it throws is a `Die`. No type is named `IO`, `Task` or
   `Future` (CT-003). `sync`, `async`, `start` and `await` are free names
   (`crit-names2-{113,110}`).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| `totask` returns a Base `Task` whose `fetch` throws the original | Impossible: Base always wraps (EFF-05). |
| `throwto` to stop a foreign task | It corrupts running tasks (EFF-04). |
| Wait uninterruptibly on a foreign task | `timeout` would hang on a silent peer. |
| Abandon the task without counting it | The leak is invisible to tests. |
| Read errors through `for x in ch` | Silent on 1.10 (STR-13). |
| Separate `Future`/`IOAction` types | They are second runtimes in disguise (obligation 1), and the names collide or need aliases. |

## Consequences

- **Contract conflicts for the lead** (written up as a note, not a contract edit):
  - **(B1)** Effect → Task cannot throw the original from a Base `Task`'s `fetch`. Proposed
    wording: "`fetch` on the returned `Fiber` throws the original; on a Base `Task` from `totask`,
    `fetch` throws `TaskFailedException` whose `task.exception === original`".
  - **(B2)** A started foreign `Task` cannot be stopped without a canceller. Proposed wording:
    "cancelling a `fromtask` effect runs its canceller if one was given, otherwise abandons the
    task".
  - **(C3)** "Error channel" means the `Cause` (ADR-0002 §3). The round trip keeps exceptions,
    values and cancellation, but a `Die` comes back as a `Fail` (§4).
- ChuiFrames' asynchronous I/O must pass cancellers, for example closing the file or socket, to
  be cancellable.

## Verification

- EFF-05, EFF-09, EFF-15, EFF-16, EFF-19, EFF-20, STR-13, STR-14.
- `.lanes/evidence/crit-fetch10-{113,110}`: `fetch threw: (TaskFailedException, true)` and
  `body rethrows original -> fetch threw: TaskFailedException` on both versions.
- Name evidence is in `names-*`, `runtime-names-*` and `crit-names2-*`. Scripts are in
  [`docs/research/scripts/`](../research/scripts/).
- UNVERIFIED: the adapters are designed, not built. The round-trip properties are phase-3 tests.

## Revisit when

- The lead or the user decides the B1/B2 wording, or Julia 1.14 makes Base tasks cancellable.
