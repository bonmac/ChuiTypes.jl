# Phase 4 design: futures and streams

- **Lane:** `phase4-streams`, branch `feat/phase4-streams`, from `main` at `bd8bcc0`.
- **Tier:** T2 (public API). Binding inputs: ADR-0002, ADR-0003, ADR-0004, ADR-0006, ADR-0007,
  ecosystem ADR-0013, request R10, and ADR-0008 (Proposed in this phase).
- **Scope:** the decisions those ADRs leave open. Where this spec and an ADR disagree, the ADR
  wins and this spec is wrong.
- **Out of scope:** performance work (phase 5). Measured on this branch, iterator-level cost is
  **not** met: fused map/filter collect about 5.5× Base, `runfold` about 43× `foldl`, about 24
  allocations / 15 KB per chunk (ADR-0003 "Measured 2026-10-20",
  `.lanes/evidence/bench-streams-bd8bcc0.txt`);
  docs pages (phase 6), the ChuiCore switch-over (ADR-0004 §3).

## 1. Names proposed at the phase-4 ★

CT-003 checks every export against Base, Core and the loaded stdlibs.

| Group | Exported | Methods on Base functions | Public, not exported |
|---|---|---|---|
| Queue | `Queue`, `offer`, `receive` | `close(q)`, `isopen(q)`, `length(q)` | `QueueClosed` |
| Stream values | `Stream`, `fromiter`, `fromeffect`, `emptystream`, `failstream`, `interval`, `timer`, `bracketstream` | `eltype` | `StreamTag` |
| Element operators (fused) | `scan` | `map`, `filter`, `Iterators.take`, `Iterators.drop`, `Iterators.takewhile` | |
| Combining | `concat`, `concatmap`, `mergemap`, `switchmap` | `merge` | |
| Time | `debounce`, `throttle`, `buffertime`, `windowtime` | | |
| Grouping | `buffer`, `window` | | |
| Errors | | `retry(s, schedule)`, `catchfail(h, s)` (an existing ChuiTypes function) | |
| Boundary | `prefetch` | | |
| Hot | `Subject`, `publish`, `subscribe` | `close(subj)`, `close(subj, ex)` | |
| Running | `runcollect`, `runfold`, `runforeach`, `withbatches`, `runchunks` | | |
| Futures | `collectpar` | | |
| Adapters | `fromchannel`, `tochannel` | | |
| Marble testing | | | `marbles`, `marbletrace` |

- `take`/`drop`/`takewhile` are methods of `Base.Iterators`' functions (owned type), so no new
  name collides with `using Base.Iterators`.
- The async boundary is `prefetch`, not `async`: `async(register)` is the ADR-0006 effect.
- `buffer(s, n)` counts; `buffertime(s, d)` times. Two names, not `buffer(s, 3)` against
  `buffer(s, 3.0)`, which would make the unit depend on the literal's type.

## 2. Stream values (ADR-0003 §1)

- `Stream{T}` is an immutable struct with one field: an erased source description (`Any`). `T`
  is **advisory**, as for `Effect` (ADR-0002 §1): computed with `Base.promote_op` when the value
  is built, a supertype of every element, never asserted. `eltype(::Type{Stream{T}}) = T`.
- A run **opens** the description into a mutable puller, **pulls** it, and **closes** it once.
  The internal protocol (`stream/core.jl`):
  - `_open(src, ctx) -> puller`;
  - `_pull!(p, ctx) -> AbstractVector` (a non-empty chunk) `| nothing` (the end) `| Cause` (a
    terminal failure, errors as values: ADR-0003 §8);
  - `_close!(p, ctx)`: idempotent; stops the puller's fibers (interrupt, then a masked await) and
    runs its releases. Never interruptible.
- The run driver checks the fiber's cancel state between pulls, so a loop of pure chunks stops at
  the next chunk boundary. A user function that throws becomes `Die(ex, bt)` at the pull that
  called it.
- `_CTX` (the ScopedValue bridge) is set **once per run** and once per producer fiber, not per
  chunk: `checkcancel()` and nested `run`s inside user functions see the fiber.
- Each pull dispatches dynamically on the puller (about 100 ns), once per chunk; the in-chunk
  loops are separate functions specialised on the chunk and transducer types (the function
  barrier of ADR-0003 §1).
- Sources: `fromiter(itr; chunksize = 1024)` (re-iterates `itr` on every run: cold),
  `fromeffect(eff)` (one element, the effect's value; its failure fails the stream),
  `emptystream(T)`, `failstream(e)` (`Fail(e)`), `interval(d)` (cold: `0, 1, 2, …`, one element
  every `d` seconds on the environment clock from the moment of subscription, each a one-element
  chunk).
- Resources: `bracketstream(acquire::Effect, release)` is a one-element stream of the acquired
  value; `release(a, exit)` (an effect) runs masked when that stream's puller closes, exactly
  once, whatever ends the run (fs2's `Stream.bracket`). Use it with `concatmap`:
  `concatmap(h -> fromiter(readlines(h)), bracketstream(open_effect, close_effect))`.

## 3. Fused element operators (ADR-0003 §2, ADR-0004)

- `Upstream` gains stand-ins mirroring ChuiCore main's transducer substrate (ChuiCore ADR-0003):
  `Transducer`, `Map`, `Filter`, `Take`, `TakeWhile`, `Scan`, `Partition`, `Composed`, `Reduced`,
  `reduced`, `unreduced`, `isreduced`, `R`, `Bottom`, `asrf`, `start`, `next`, `complete`,
  `foldxl`, and `opcompose` (ChuiCore's `⨟` binding; ChuiTypes does not define `⨟`). Same field
  names and the same per-fold state in the accumulator (`_State`), so the switch-over replaces
  each with a `using`.
- `map`, `filter`, `scan`, `take`, `takewhile`, `buffer(n)` (`Partition`) on a stream compose
  into **one** `_Fused(src, xf)` node: `map(g, map(f, s))` has one transducer `Map(f) ⨟ Map(g)`
  over `s`'s source. `drop(s, n)` is a small stateful transducer of ChuiTypes (`_Drop`), not in
  ChuiCore.
- A run builds the reducing function once, `asrf(xf, _sinkpush)`, whose bottom accumulator is
  a mutable `_Sink` (critic 6): `start` runs once, so stateful transducers (`Scan`, `Take`,
  `_Drop`, `Partition`) carry their state across chunks inside the accumulator, and the sink's
  vector field is swapped out as the emitted chunk (no copy). An empty output pulls again.
- **Widening, never converting** (critic 6, ADR-0002 §1): the sink's vector starts as
  `Vector{T}` of the advisory `T`; an element that is not `isa T` switches the sink to a
  `Vector{Any}` that is narrowed (`map(identity, …)`) when emitted. `T` is never asserted and a
  value is never `convert`ed.
- `Reduced` (a `take` finishing): run `complete` (which may flush, e.g. `Partition`'s group, so
  `buffer(take(s, 5), 3)` gives `[[1,2,3],[4,5]]`), emit the partial chunk plus the flush, close
  the upstream at once (its fibers stop, its releases run), and end.
- At the upstream's end: `complete`, emit what it produced, end.
- `scan(op, init, s)`: Rx `scan`, emits every intermediate accumulator (not `init` itself).
- `buffer(s, n)` emits `Vector{T}`s of `n` elements (the last one shorter); `window(s, n)` emits
  each group as a finite `Stream{T}` over the buffered group (a pull stream cannot hand out a live
  inner stream without a boundary per window; this differs from Rx and is documented).

## 4. `Queue{T}` (ADR-0002 §4, ADR-0003 §3)

- `Queue{T}(capacity)`: bounded FIFO (capacity ≥ 1). Waiters are `_Waiter`s on the queue's lock;
  every wait is "ready **or** the caller's own cancellation" (`_park!`), so a cancelled producer
  wakes without closing a shared queue.
- Internal: `_put!(q, x, ctx) -> (ok, nothing | Cause)`, `_take!(q, ctx; deadline) -> (ok, x |
  :timeout | Cause)`, `_tryput!`, `_trytake!` (never block). `deadline` is a time on the context's
  clock (`VirtualClock` timer or a Base `Timer`), used by `debounce` and `buffertime`.
- Public: `offer(q, x)` and `receive(q)` effects; `close(q)`: later `offer`s fail with
  `Fail(QueueClosed())`, `receive` drains what is queued and then fails with
  `Fail(QueueClosed())`. Waiting putters and takers wake.
- **Wake-ups are broadcasts** (critic 4): every change (an item added, an item removed, a
  close) fires **all** waiters of the other side and clears them; each re-tests under the lock
  and re-registers if it lost. A waiter that was fired and then cancelled therefore cannot
  swallow the only wake-up. Waiters are few (one per producer fiber), so the herd is small.
- A `Queue{Nothing}(n)` is also the semaphore of `mergemap`/`collectpar` (`_put!` acquires,
  `_trytake!` releases).

## 5. Concurrent operators (ADR-0003 §4, §7)

- **Producer fibers ("pumps").** A pump opens a stream inside its own fiber, pulls it and puts
  messages on a shared queue: `_Msg(tag, chunk)`, `_Msg(tag, :done)` or `_Msg(tag, cause)`. It
  closes its puller in a `finally`. Pumps are **unsupervised** children (`_forkin(ctx, …, false)`,
  as `race` uses): a failure reaches the consumer as a message, so errors stay values; they are
  still in the run's `Scope`, whose exit awaits them.
- Default queue capacity: 4 chunks per producer for `merge`, 4 in total for the others.
- `merge(a, b, …)`: one pump per input; ends when every input has ended; the first failure is
  the stream's failure (the others are interrupted at close). Order: chunk arrival order.
- `concat(a, b, …)`: sequential, no fibers; `a` is closed before `b` opens.
- `concatmap(f, s)`: for each element `x`, run `f(x)::Stream` to its end, in order; no fibers.
  It is the stream monad's `chain`.
- `mergemap(f, s; maxconcurrent = 16)`: a coordinator fiber pulls `s`; for each element it
  acquires a semaphore slot (cancellable), then forks an inner pump for `f(x)`; a finishing
  inner releases its slot. When `s` ends, the coordinator sends `_Msg(:outerdone, n)` with the
  number of inners it started (critic 8); the consumer counts inner `:done` messages whatever
  their order and ends when it has the outer's end and `n` inner ends.
- `switchmap(f, s)`: the coordinator keeps a generation counter (atomic). For each element it
  **first bumps the generation** (critic 8), then interrupts the previous inner **without
  waiting**, and forks a new inner that tags its messages with the new generation. The consumer
  drops every message (chunk, end or failure) whose generation is not the current one. The
  coordinator awaits the interrupted inners at its exit, after the handoff (ADR-0003 §4). It
  ends when the outer stream and the latest inner have ended.
- **Upstream leases** (critic 2). A concurrent operator closes an upstream puller only when it is
  itself closed, or when nothing downstream can still use that upstream's elements:
  - a `merge`/`prefetch`/time-operator pump that reaches its input's end sends `:done` and then
    **parks until the operator closes it**, and only then closes its input (a fixed number of
    pumps per operator, so parked pumps are bounded);
  - the `mergemap`/`switchmap` coordinator closes its outer puller only after every inner it
    started has ended, so `mergemap(h -> lines(h), bracketstream(open, close))` releases `h`
    after the inners that read it;
  - a `mergemap` inner pump closes its own input at its own end (otherwise an unbounded outer
    would keep every finished inner alive). A resource **acquired inside** an inner is released
    when that inner ends, possibly before downstream has used its last elements; documented:
    use such a resource inside the inner stream.
- **Close order** (every concurrent puller): interrupt every fiber it owns, then await each,
  masked; then close its own pullers. A producer woken by its own cancellation ends
  `Interrupted`, never failed (ADR-0003 §7).
- `prefetch(s; capacity = 4)`: one pump; decouples a producer from its consumer (Rx's
  `observeOn`/`subscribeOn`).

## 6. Time operators (ADR-0003 §9)

All read the environment clock (`_clockof(ctx)`), so they run on virtual time under `runtest`.
An element's time is the time its chunk is pulled by the operator.

- `throttle(s, d)`: leading edge. An element passes if no element passed in the last `d`
  seconds (`now >= last + d`); the others are dropped. No fiber. **Ties:** in one chunk only the
  first element can pass.
- `debounce(s, d)`: a pump for `s`; the consumer keeps the latest element and a deadline
  `now + d`, and waits on the queue until the deadline. On expiry it emits the kept element. On
  the end it emits the kept element, then ends (Rx). On a failure the kept element is dropped
  (Rx). **Ties are decided by time, not by timer order** (critic 1): whenever the consumer wakes,
  for any reason, and `now >= deadline`, the kept element is emitted first; a chunk that arrived
  at that instant is then handled as a new arrival. So an arrival exactly at the deadline does
  not suppress the kept element: `debounce(marbles("a-b|"), 2)` is `--a(b|)`. A chunk counts as
  one arrival; its last element is kept.
- `buffertime(s, d)`: a pump; emits the elements gathered in each window `[t0 + kd, t0 + (k+1)d)`
  as one vector, skipping empty windows (unlike Rx, which emits empty buffers); at the end,
  emits the partial window. **Ties by time:** an element at exactly a window boundary belongs to
  the next window. A window timer is scheduled only while the current window holds elements, so
  an idle source schedules no timers (no endless virtual-time loop under `runtest`).
- `timer(d)`: cold, one element `0` after `d` seconds, then the end (ADR-0003 §9). `interval`
  and `timer` are **cold** here (each run has its own ticks from its subscription); ADR-0003 §5
  lists timers among hot sources. Flagged for the ★: a hot timer is `subscribe` on a `Subject`
  fed by `runforeach` of a cold one.
- `windowtime(s, d)`: as `buffertime`, each group wrapped as a finite `Stream{T}` (§3).
- `retry(s, sched::Schedule)`: on `Fail(e)`, close the run of `s`, wait the schedule's delay and
  run `s` again from the start; elements already emitted stay emitted (Rx `retry`). `Die` and
  interruption are not retried.
- `catchfail(h, s)`: on `Fail(e)` continue with the stream `h(e)`.

## 7. Hot sources (ADR-0003 §5)

- `Subject{T}(; capacity = 1024, overflow = :block)`: each subscriber has its own bounded buffer
  counted in **elements**; `overflow ∈ (:block, :dropnewest, :dropoldest, :latest)` applies per
  element (`:latest` keeps only the newest element).
- `subscribe(subj)::Stream{T}`: a run registers a subscriber buffer at open and removes it at
  close. Emissions published while nobody is subscribed are dropped (Rx `Subject`).
- `publish(subj, x)::Effect`: delivers `x` to every current subscriber. Under `:block` it waits,
  cancellably, for space in each full buffer, so the slowest subscriber paces the publisher; a
  consumer that publishes into its own blocked subject deadlocks (documented; use `:dropnewest`).
- `close(subj)` ends every subscription after its buffered elements; `close(subj, ex)` fails
  them with `Fail(ex)`. Later subscriptions end (or fail) at once. `publish` after `close` does
  nothing (Rx ignores `onNext` after completion).
- Removing a subscriber (its run closes) and `close(subj)` **wake every publisher** blocked on
  that subscriber's buffer (critic 5); a woken publisher re-checks and skips subscribers that
  are gone. A cancelled `publish` may have delivered to only some subscribers (documented).
- A subscriber's pull takes all buffered elements (up to 1024) as one chunk: partial chunks, so
  a hot source never waits to fill a chunk.
- **Departure from ADR-0003 §5, for the ★** (critic 13). The ADR says hot sources are built on
  ADR-0006 `async` with a canceller. The subscriber buffer instead waits with the runtime's
  cancellable `_park!` directly; it has the semantics `async` would give (the canceller is the
  subscriber's own cancel state) without a closure and a callback per wait. This needs an
  ADR-0003 §5 amendment at the ★ (proposed wording: "built on the runtime's cancellable waits,
  as `async` is").

## 8. Running (ADR-0003 §6, §10)

- `runcollect(s)::Effect{Any,Vector}` (the vector's element type is the tightest of the
  elements', as `map(identity, …)` gives; the error parameter is `Any`, streams can fail),
  `runfold(op, init, s)`, `runforeach(f, s)` (`f` a plain function per element). Each is
  `scope(…)`: leaving it, by end, error or interruption, interrupts the run's fibers, awaits
  them and runs the finalizers LIFO (ADR-0003 §7).
- `withbatches(f, s)`: a plain call (it runs the stream like `run`, nested under an enclosing
  `sync`'s fiber if any). It calls `f(it)`, where `it` iterates the chunks in order
  (`Base.SizeUnknown()`); a failure throws from `iterate` as `run` would throw it (the original
  exception, ADR-0002 §3). `it` is valid only inside `f`: iterating it afterwards throws an
  `ArgumentError`. Leaving `f` closes the run. Returns `f`'s value.
- `runchunks(s; maxelements = nothing)`: an effect giving the chunks, in order, as a snapshot;
  every chunk is a fresh vector owned by the run (no view of a user's array). With
  `maxelements = n`, a stream with more than `n` elements fails with `Fail(ArgumentError(…))`
  after reading `n + 1`: this bounds memory, not time (wrap it in `timeoutfail` for that). This
  is the bounded Source path (§10, ADR-0008).

## 9. Adapters (ADR-0006 §5)

- `fromchannel(ch)`: hot, single-consumer. A pull waits until `ch` is ready **without taking**
  (`wait(ch)` in a helper task behind the ADR-0006 `async` protocol, abandon mode), then drains
  with `take!` up to 1024 ready items as one chunk. `InvalidStateException` with state `:closed`
  ends the stream; any other exception from `take!` (the `close(ch, ex)` exception, or a
  `TaskFailedException` from `bind`, unwrapped) fails it with `Fail(ex)`. `ch.excp` is never read.
  - Cancelling a pull while the channel is empty abandons the helper task, which stays blocked in
    `wait(ch)` until the channel gets an item or closes; it **takes nothing**, so no item is lost.
    It is counted in `orphans()`. Repeated cancels on one empty channel stack one helper each
    (documented).
  - **Test mode** (critic 9): the helper is outside work behind `async` and is **not** counted
    as a live test-mode fiber, as for a real `Timer` callback (ADR-0006 §1 docs): virtual time
    may advance while it waits, so `timeout(runcollect(fromchannel(ch)), 1.0)` under `runtest`
    times out instead of hanging.
  - Verified on 1.10.12 and 1.13.2 (`.lanes/evidence/chfacts-*`): `wait` on a closed channel
    with items returns; on a closed empty channel it throws `InvalidStateException(:closed)`; on
    a channel closed with `ex` it throws `ex`; `take!` behaves the same.
- `tochannel(s; size = 0)`: returns a `Channel{T}(size)` filled by a new root fiber (real time)
  that runs `s` and `put!`s each element; at the end it `close`s the channel, on failure
  `close(ch, ex)` with `run`'s exception. **Closing the channel from the consumer side cancels
  that fiber** (ADR-0006 §5; critic 3): a Base `Timer` polls `isopen(ch)` every 10 ms and calls
  `interrupt!` on the fiber, so a fiber parked upstream (`interval(3600)`, a quiet subject) stops
  within about 10 ms, and a `put!` that throws on the closed channel stops it at once. The
  timer is closed when the fiber ends.

## 10. The bounded Source path (R10; ADR-0008, Proposed)

ChuiTypes **guarantees** what a ChuiFrames adapter (in ChuiFrames, ecosystem ADR-0002 §1) needs
to build a CF-011 bounded `Source` by **snapshotting at construction**, as `TablesSource` does for
any Tables.jl input; the adapter's own rules go to ChuiFrames through R10 (critic 10a):

1. `runchunks(s; maxelements)` once, when the source is built, gives fresh, owned vectors that
   ChuiTypes never touches again: re-readable and thread-safe, so `explain` followed by
   `collect` plans the same partitions (CF-011), whatever the stream's timing. The adapter may
   coalesce consecutive chunks deterministically (for example to `morsel` rows), since hot
   sources give small partial chunks (critic 10d).
2. Schema: `eltype(s)` is a supertype of every element. If it is a concrete
   `NamedTuple{names, types}`, that is the schema; otherwise the adapter computes it from the
   snapshot (or the user passes one). An empty stream needs `eltype` or a user schema.
3. A cold stream re-run yields the same **elements** when its sources are deterministic, but
   chunk boundaries and interleavings (`merge`, hot sources, time operators) may differ, so the
   adapter must not re-run the stream per partition.
4. Streaming (unbounded) sources stay out of v0 (CF-015).

ChuiTypes tests this path without a ChuiFrames dependency (a mock source over `runchunks` in
`test/test_stream_source.jl`).

## 11. Futures (ADR-0006 §6)

- A Fluture-style future is an `Effect`: lazy (building one starts nothing), cancellable
  (`interrupt!` → the `async` canceller runs), and composable (`andthen`, `map`, `race`,
  `zippar`). Tests (`test/test_futures.jl`) state the Fluture correspondence, and the
  Folktale `Task` one (`task(resolver)` with `onCancelled` is `async` with a canceller).
- `collectpar(effs; maxconcurrent = 16)`: run the effects with at most `maxconcurrent` at once
  and succeed with their values **in input order**; the first failure interrupts and awaits the
  rest and fails with it (Fluture's `parallel`).

## 12. Typeclass instances

- `Stream` is a Functor (`map`) and a Monad (`pure(StreamTag(), x)` is a one-element stream,
  `chain` is `concatmap`). `Upstream.fmap/pure/ap/chain` methods, with law tests comparing
  `runcollect` results. Rule N5: Upstream has no style layer yet, so the methods are
  `Upstream.fmap(f, s::Stream)`; at the switch-over they become
  `ChuiCore.fmap(::ChuiCore.IsFunctor, f, s::Stream)` with the style typed, never `_`.

## 13. Marble tests (ADR-0003 §9)

- `ChuiTypes.marbles(spec; values = nothing, error = ErrorException("marble error"), frame =
  1.0)`: a cold source. Grammar (one character = one frame, except a group): `-` an empty frame;
  any other non-space character an element (the `Char`, or `values[Symbol(c)]`); `(…)` a group
  of elements (and at most one terminal) in **one** frame; `|` the end; `#` the failure
  `Fail(error)`; spaces are ignored. Without a terminal the source never ends (RxJS). At subscription it reserves one virtual-clock sequence block
  for all its events, so same-instant ties across sources follow **subscription order**, as if
  every event had been scheduled at subscription (ADR-0003 §9).
- `ChuiTypes.marbletrace(s; frame = 1.0, frames = 100, names = nothing)::Effect{…,String}`:
  runs `s`, records each element's frame (`round(Int, (t - t0) / frame)`, `t0` the trace
  start) and renders the same
  grammar (`names` maps values back to characters; by default an element prints as its string,
  which must be one character). Stops after `frames` frames without a terminal.
- Marble tests run under `runtest`; every operator in the brief's list has at least one, listed
  in `test/test_stream_marbles.jl`'s header.

## 14. Tests (written first)

| File | Tag | What |
|---|---|---|
| `test_queue.jl` | `:unit` | FIFO, bounds, cancellable put/take, close, deadline |
| `test_stream.jl` | `:unit` | sources, fusion (one `_Fused` node), chunking, run functions, errors as values, `withbatches` |
| `test_stream_marbles.jl` | `:unit` | every operator on virtual time |
| `test_stream_hot.jl` | `:unit` | `Subject` policies, late subscribers, close |
| `test_stream_adapters.jl` | `:unit` | `fromchannel`/`tochannel` on both versions' semantics |
| `test_stream_source.jl` | `:unit` | the bounded Source path (§10) |
| `test_futures.jl` | `:unit` | Fluture correspondence, `collectpar` |
| `test_stream_props.jl` | `:property` | fusion equals the list model; cancellation at a random chunk leaves no live fiber (per-test `VirtualClock.live`); every release runs once |
| `laws/test_laws_stream.jl` | `:laws` | Functor and Monad laws |
| `laws/test_planted.jl` | `:property` | a planted violation per stream property (runs on 1.10) |
| `test_stream_stress.jl` | `:slow` | 10^3 `switchmap`/`mergemap`/`merge` runs interrupted at random; leaks via per-test counters |

- **Bounds:** every property has a wall-clock budget (`budgeted`), every fiber wait and every
  stress section a hard bound that fails loudly; full suites run under `perl -e 'alarm 1500;
  exec @ARGV'`.
- **Leak checks use per-test counters**, never the process-wide `livefibers()` of a shared test
  process: in test mode a run's `VirtualClock` counts its live fibers (`clock.live` back to 0
  after the run); in real mode each test counts its own resources with `bracketstream` and a
  local atomic counter (acquired == released), and the real-time stress section runs in a
  **child Julia process** of its own, where `livefibers()` returning to its baseline is a
  per-test counter (critic 11).
- **ADR-0004 and the transducer stand-ins** (critic 12, for the ★): the `Upstream` transducer
  stand-ins are a minimal re-implementation of ChuiCore's *protocol* (names, fields, the
  `start`/`next`/`complete` contract), not a copy of its files; only the transducers streams
  use are defined. ADR-0004 rejected vendoring ChuiCore's code; the lead decides whether this
  placeholder is within ADR-0004 §2.
