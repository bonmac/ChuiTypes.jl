# Research: stream designs and backpressure

Date: 2026-10-20. Lane: phase 1 (Research and ADRs), researcher. Status: input for the streams ADR.

**How verified.** Other-language prior art comes from Context7 (library IDs given per entry) or the
official docs fetched on 2026-10-20 (URLs given). Julia package facts come from the local General
registry snapshot (`~/.julia/registries/General.tar.gz`, read with `tar -xzOf`), the GitHub API
(`pushed_at`, fetched 2026-10-20) and installing the package into a scratch environment. Every Julia
behaviour and benchmark claim was run on **Julia 1.13.2** (`julia +release`) and **Julia 1.10.12**
(`julia +lts`) on an Apple M3 Pro (macOS, aarch64). Benchmarks were captured with
`scripts/evidence.jl` into `.lanes/evidence/` (gitignored, keyed to commit `db74452`). Scripts live in
the scratch directory `S = /private/tmp/claude-501/-Users-bonmac-personal-projects-julia-data-analysis/5c1f011c-1151-4765-9a79-8eba6d64f4e6/scratchpad/types-p1/streams/`:
`$S/channel_semantics.jl`, `$S/throughput.jl`, `$S/virtual_time.jl`, `$S/cancel.jl`,
`$S/rocket_probe.jl`, `$S/registry_search.jl`. Anything not checked is marked `UNVERIFIED`.

## 1. Prior art in other languages

| System | Push / pull | Backpressure | Cancellation, cleanup | Time ops, virtual time | Chunking |
|---|---|---|---|---|---|
| RxJS 7 | push | none built in; lossy/aggregating ops | `Subscription.unsubscribe` teardown | `debounceTime` etc.; `TestScheduler` marbles | no |
| Reactive Streams 1.0.4 | push with pull-side demand | `request(n)` | `cancel()`, idempotent, eventual | out of scope | no |
| Monix 3.4 | push | `onNext` returns `Future[Ack]` | `Cancelable`; `Stop` ack | `TestScheduler` (UNVERIFIED) | no |
| fs2 (CE 3) | pull (`Pull`, `uncons`) | implicit (pull) | interruption, `bracket`/`Resource` | `debounce`, `metered`; CE `TestControl` | `Chunk` internally |
| ZIO Streams 2.1 | pull | implicit (pull) | `Scope`; "never leak resources" | `TestClock.adjust` | chunks internally |
| Kotlin Flow | cold, suspend-based push | suspension of `emit`; `buffer`/`conflate` | coroutine cancellation | `runTest` virtual time | no |
| Akka Streams 2.10 | dynamic push/pull | demand signalling (RS) | stage completion | UNVERIFIED | no |

### STR-01: RxJS is push, hot/cold is about producer creation, marbles run on virtual time
- Claim: hot/cold is defined by whether the producer exists before the subscription; every Subject is
  hot; `share`/multicast are separate properties. `TestScheduler.run(helpers)` gives
  `cold`, `hot`, `expectObservable`, `flush`, `time`; marbles advance one frame per character and
  accept time-progression syntax (`'-- 9ms a 9ms b 9ms (c|)'`). Schedulers (`asyncScheduler`, `observeOn`)
  decide when notifications are delivered.
- Source: Context7 `/reactivex/rxjs` (docs `guide/testing/marble-testing.md`, `guide/subject.md`,
  `guide/scheduler.md`, and decision D-035 in the RxJS repo's rxjs-next DECISIONS file).
- Backpressure: the ReactiveX operator page (https://reactivex.io/documentation/operators/backpressure.html)
  lists reactive-pull `request(n)` only for RxJava 1.x / RxGroovy and names Buffer, Sample, Debounce,
  Window as the strategies for hot sources; RxJS 4 had `controlled`/`pausable`. That these were dropped
  in RxJS 5+ is from a secondary blog (codeburst.io) only: **UNVERIFIED** against the official
  RxJS migration guide. RxJS 7 having no `request(n)` protocol: consistent with the docs read, not
  stated verbatim by them.

### STR-02: Reactive Streams: demand via `request(n)`, cancel is a request
- Claim: spec 1.0.4. Backpressure = the receiver is "not forced to buffer arbitrary amounts of data";
  signals must be non-blocking. Rule 3.9: `request(n)` with `n <= 0` must signal `onError`
  (`IllegalArgumentException`); requests are additive. 3.5: `cancel` "MUST be idempotent and MUST be
  thread-safe". 3.12: publisher must "eventually stop signaling". 3.13: must "eventually drop any references".
- Source: https://github.com/reactive-streams/reactive-streams-jvm/blob/master/README.md (fetched 2026-10-20).

### STR-03: Monix: push where every `onNext` returns an acknowledgement
- Claim: "the producer will wait for an `Ack` from the consumer before sending the next element";
  `onNext` returns `Future[Ack]`; `Continue` or `Stop`, and `Stop` propagates upstream.
  `subscribe()` returns a `Cancelable`. `Observable.create` buffers by an `OverflowStrategy`.
- Source: https://monix.io/docs/current/reactive/observable.html (Monix 3.x, source tag v3.4.0, page
  updated 2022-03-29). Monix `TestScheduler` virtual time: **UNVERIFIED** (not fetched).

### STR-04: fs2: pull-based, chunked, interruption-safe finalizers, virtual time from the effect runtime
- Claim: "FS2 streams are internally chunked for performance. A `Chunk` is a strict, finite sequence";
  `Pull` is the primitive under `Stream`; `s.pull.uncons` yields `Option[(Chunk, Stream)]`.
  `Stream.bracket` release runs "exactly once ... even in the case of errors or interruptions";
  for cleanup "always use `bracket` ... avoid `handleErrorWith` or `++`, as they are interruptible".
  Interruption: `interruptWhen(deferred)`, `interruptAfter(d)`; time ops `debounce`, `metered`.
- Source: Context7 `/typelevel/fs2` (`site/guide.md`, llms.txt, `migration-guide-1.0.md`).
- Virtual time comes from Cats Effect `TestControl` (testkit 3.7.1): clock "only advances in response
  to external reconfiguration"; `tick` runs until all fibers sleep, `advance`/`advanceAndTick` move
  time; fiber choice at yield points is random unless seeded.
  Source: https://typelevel.org/cats-effect/docs/core/test-runtime (fetched 2026-10-20).

### STR-05: ZIO Streams: pull, chunks, scope-based safety, `TestClock`
- Claim: "ZIO uses pull-based streams"; "ZIO Streams are working at the level of chunks"; it "does not
  need back-pressure ... because it is lazy and on-demand"; "provides the guarantee that it will never
  leak resources" on error, timeout or interruption, via `Scope`. `TestClock`: "The clock time never
  changes by itself"; `adjust`/`setTime` run every effect scheduled on or before the new time, in order.
- Source: https://zio.dev/reference/stream/ (zio-streams 2.1.27), https://zio.dev/reference/test/services/clock/.
  `ZChannel` internals: **UNVERIFIED** (the page only links it).

### STR-06: Kotlin Flow: cold, suspension is the backpressure, explicit lossy operators
- Claim: `buffer(capacity, onBufferOverflow = SUSPEND)` runs the collector in a separate coroutine via a
  channel; `conflate()` = `buffer(0, DROP_OLDEST)`, "the emitter is never suspended due to a slow
  collector" (so without it, it is); `flatMapLatest` cancels the previous inner flow (= `switchMap`);
  adjacent buffer operators fuse into one channel. `runTest` + `TestCoroutineScheduler`:
  `runCurrent`, `advanceTimeBy`, `advanceUntilIdle`; `delay` waits on virtual time.
- Source: Context7 `/websites/kotlinlang_api_kotlinx_coroutines` (`conflate.html`, `flat-map-latest.html`,
  flow `index.html`, `kotlinx-coroutines-test/index.html`).

### STR-07: Akka Streams: demand-based "dynamic push/pull"
- Claim: back-pressure is measured by demand (elements downstream can receive and buffer); the protocol
  switches between push and pull depending on whether downstream keeps up. A graph is a reusable
  "blueprint" that "can be materialized multiple times" (cold in effect).
- Source: https://doc.akka.io/libraries/akka-core/current/stream/stream-flows-and-basics.html (Akka 2.10.24).
  Akka Streams virtual-time testing: **UNVERIFIED**.

**Pattern across these.** The systems that carry bulk data (fs2, ZIO, Akka, Reactive Streams) all have
a pull or demand signal, and fs2 and ZIO also chunk. The UI/event systems (RxJS, Observables.jl) are pure
push and use lossy operators instead. All of them make time operators testable by putting the clock
inside the scheduler or runtime.

## 2. Julia prior art

### STR-08: registry snapshot search
- Command: `julia +release --startup-file=no $S/registry_search.jl Rocket Observables Signals Reactive Transducers ResumableFunctions Continuables IterTools`
  (reads `Registry.toml`, `Versions.toml`, `Compat.toml`, `Deps.toml` out of the tarball; 14577 entries).
- Stream-ish names found (trimmed): Rocket, Rocketeer, ReactiveMP, RxInfer, RxEnvironments, Observables,
  GtkObservables, Observers, Reactive, ReactiveGraphs, ReactiveToolkit, Signals, Transducers, Folds,
  FoldsThreads, ResumableFunctions, Continuables, IterTools, DataFlowTasks, Pipelines, DataPipes,
  ChannelBuffers, PriorityChannels, AtomicChannels, LengthChannels, PipeChannels, StreamCallbacks,
  DataStreams, Lazy, TranscodingStreams, BufferedStreams. None besides Rocket is a general
  observable library with time operators (by name and the entries below; the rest were not opened).

### STR-09: Rocket.jl 1.11.0: push, synchronous by default, no demand protocol
- Registry: 55 versions, latest 1.11.0; compat for 1.8.3+: `DataStructures = "0.17 - 0.19"`,
  `Unrolled = "0.1.3 - 0.1"`. GitHub `ReactiveBayes/Rocket.jl`: `pushed_at` 2026-10-19, not archived,
  MIT, 222 stars. Docs (https://reactivebayes.github.io/Rocket.jl/stable/, Documenter 1.19.0) do not
  mention backpressure; schedulers `AsapScheduler`, `AsyncScheduler`, `ThreadsScheduler`.
- Source (`~/.julia/packages/Rocket/7wUAn/src/schedulers/async.jl`): `AsyncScheduler(size = typemax(Int))`
  wraps a `Channel(size)` consumed by one `@async` task; so the default is unbounded and a bounded size
  gives blocking backpressure via `put!`.
- Command: `julia +release --startup-file=no --project=$S/rocket113 $S/rocket_probe.jl` and
  `julia +lts --startup-file=no --project=$S/rocket110 $S/rocket_probe.jl`. Output, 1.13.2 (1.10.12 identical except timings):
  ```
  VERSION=1.13.2  Rocket 1.11.0
  Rocket direct deps: ["DataStructures", "Sockets", "Unrolled"]
  total packages in manifest (transitive, excl. Rocket): 5
  from(1:10) |> map |> filter |> scan(+) => [2, 6, 14, 24, 38, 54, 74]
  Subject: early subscriber got [1, 2, 3], late subscriber got [3, 4]
  sync Subject + slow actor (10 ms each): emitting 20 took 0.3 s (producer blocked = synchronous call, no demand signal)
  AsyncScheduler() [unbounded]: after 30 ms emitted=50 processed=0
  AsyncScheduler() [unbounded]: after 530 ms emitted=50 processed=50
  AsyncScheduler(4): after 30 ms emitted=12 processed=6        # 1.10.12: emitted=11 processed=5
  Rocket from(vector)|>map|>filter push: 1.26 ns/item (min of 5)   # 1.10.12: 1.03 ns/item
  ```
- Reading: Rocket installs and works on both versions; it is light (3 direct deps, 5 total). Its
  "backpressure" is either the synchronous call stack or a bounded scheduler channel; there is no
  `request(n)`. Its Subjects are hot, `from` is cold.

### STR-10: Observables.jl, Reactive.jl, Signals.jl
- Observables 0.5.5 (registry; julia compat `1.6.0-1`; its Deps.toml lists only `Test`, for 0-0.2, so 0.5 has no deps);
  `pushed_at` 2026-07-01. Docs (https://juliagizmos.github.io/Observables.jl/stable/): "Observables are
  synchronous"; `obs[] = val` calls listeners; `async_latest` "drops all but the last `n` updates";
  `throttle(dt)`. A UI-state cell, not a stream library: no completion, no error channel (UNVERIFIED
  beyond the docs read), no virtual time.
- Reactive.jl 0.8.3 (registry), `pushed_at` 2020-02-08: unmaintained.
- Signals.jl 1.2.0 (registry, julia `1.2.0-1`), `pushed_at` 2022-04-23: unmaintained.

### STR-11: pull-side building blocks
- Transducers.jl 0.4.85 (registry; julia `1.10.0 - 1`), `JuliaFolds2/Transducers.jl` `pushed_at`
  2025-09-11. Installed on 1.13.2: 14 direct deps (Accessors, ArgCheck, BangBang, Baselet,
  CompositionsBase, ConstructionBase, DefineSingletons, Distributed, InitialValues, Logging, Markdown,
  MicroCollections, SplittablesBase, Tables), 42 packages total in the manifest. Command:
  `julia +release --project=$S/xf113 -e 'using Pkg; Pkg.add("Transducers"); ...'` (printed above counts).
  Too heavy to depend on; ChuiCore's own transducer substrate is the intended reuse.
- ResumableFunctions 1.0.8 (julia `1.10.0 - 1`, deps MacroTools, Logging), `pushed_at` 2026-10-04: maintained.
- Continuables 1.0.3 (julia `1`), `pushed_at` 2023-07-01: quiet.
- IterTools 1.10.0 (julia `1.8.0-1`). Base `Iterators` (`map`, `filter`, `take`, `partition`, `flatten`)
  covers the pull side for finite and infinite iterators with no dependency.

## 3. Experiments (both Julia versions)

### STR-12: a bounded `Channel` blocks the producer (backpressure by blocking)
- Command: `for v in release lts; do julia +$v --startup-file=no $S/channel_semantics.jl; done`
- Output (identical on 1.13.2 and 1.10.12):
  ```
  A1 after 0.2s without consumer: produced=4 buffered=5 producer state=blocked in put!
  A2 consumer got [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]; iteration ended after close (isopen=false)
  ```
  `Channel{Int}(4)`: four `put!` complete, the fifth blocks until the consumer takes. (`Base.n_avail`
  reports 5: it counts the blocked putter too.) `close(ch)` ends `for x in ch` after the buffer drains.

### STR-13: `close(ch, ex)`: `take!` throws `ex` itself; iteration differs between versions
- Output, both versions:
  ```
  B1 isopen=false isready=true
  B2 take! of buffered item after close(ch,ex): 1
  B3 take! on empty closed-with-ex channel threw: MyErr => MyErr("boom")
  B5 take! on plain-closed empty channel threw: InvalidStateException
  ```
- Output differs for `for x in ch` over a channel closed with an exception:
  ```
  1.13.2:  B4 iterated 1 / B4 iteration threw: MyErr => MyErr("boom-iter")
  1.10.12: B4 iterated 1 / B4 iteration ended normally (no throw)
  1.11.7:  B4 iterated 1 / B4 iteration ended normally (no throw)
  ```
- Source confirms it: 1.13.2 `base/channels.jl:705-727` `iterate(c::Channel)` rethrows `c.excp` when the
  channel is closed with a non-`InvalidStateException`; 1.10.12 `base/channels.jl:610-624` returns
  `nothing`. The change landed in 1.12 or 1.13 (1.12 not installed: **UNVERIFIED** which).
  Consequence: on the 1.10 floor, a stream that ends with an error must not rely on iteration to
  surface it; carry the error explicitly (e.g. a terminal error item, or check `ch.excp`/the bound task).

### STR-14: `bind(ch, task)`: a failing producer surfaces as `TaskFailedException`
- Output, both versions:
  ```
  C1 consumer saw: TaskFailedException items=[1, 2]
  C1 inner: ErrorException => ErrorException("producer failed")
  C2 Channel(f) failing f: consumer saw TaskFailedException inner=MyErr
  ```
  Items put before the failure are delivered; then the consumer gets the wrapped exception (the original
  is at `e.task.exception`). `Channel(f)` binds implicitly and behaves the same. This path works on 1.10.

### STR-15: consumer-side close cancels a blocked producer; abandoning a channel leaks the producer
- Output, both versions:
  ```
  D1 producer blocked in put! after consumer close(ch) gets: InvalidStateException
  E1 took [1, 2, 3]; producer done after take(3)? false (blocked forever unless channel closed)
  E2 after close(ch): producer done=true failed=true
  ```
  `Iterators.take(ch, 3)` leaves the producer task parked forever; only `close` releases it. So a
  Channel-backed stream needs scoped consumption that closes on exit.

### STR-16: scoped consumption gives cooperative cancellation with finalizers
- Command: `for v in release lts; do julia +$v --startup-file=no $S/cancel.jl; done`. Output identical on both:
  ```
  1 got [[1, 2, 3, 4], [5, 6, 7, 8]]  producer log ["acquire", "producer saw InvalidStateException", "release"]  task done=true
  2 consumer error consumer failed; producer log ["acquire", "producer saw InvalidStateException", "release"]
  3 consumer failed with InterruptException; producer log ["acquire", "producer saw InvalidStateException", "release"]
  ```
  `withbatches(f, s)` = `try f(s.ch) finally close(s.ch); wait(s.task) end`. Early `break`, a consumer
  error, and an outside `schedule(t, InterruptException(); error=true)` all close the channel; the producer
  sees `InvalidStateException` at its next `put!` and runs its `finally` (resource release). Cancellation is
  cooperative: it lands only at a blocking point; a producer in a tight non-yielding loop is not interrupted.

### STR-17: throughput: chunks are what make a Task/Channel boundary affordable
- Pipeline everywhere: `map(x -> x + 1) |> filter(x -> x % 3 != 0) |> sum` over a runtime `Vector{Int}`;
  min of 5 runs. Per-item Int channel cases use n = 5000 (`NI=5000`) because a per-item handoff is slow;
  all others n = 10^6. Evidence files (`.lanes/evidence/`): `streams-tp-113-t1-db74452.txt`,
  `streams-tp-113-t2-db74452.txt`, `streams-tp-110-t1-db74452.txt`, `streams-tp-110-t2-db74452.txt`. Command, e.g.
  `NI=5000 julia --startup-file=no scripts/evidence.jl streams-tp-113-t1 -- julia +release --startup-file=no -t 1 $S/throughput.jl`.
- ns/item, copied from those files (`-t 1` | `-t 2`):

  | case | 1.13.2 t1 | 1.13.2 t2 | 1.10.12 t1 | 1.10.12 t2 |
  |---|---|---|---|---|
  | iterator (`Iterators.map/filter`) | 0.32 | 0.32 | 0.32 | 0.31 |
  | transducer-like `foldl` | 0.32 | 0.32 | 0.36 | 0.51 |
  | push callbacks (mini observable) | 0.32 | 0.32 | 1.03 | 0.63 |
  | push callbacks, chunks of 1024 | 0.45 | 0.34 | 0.38 | 0.52 |
  | `Channel{Int}(0)` @async | 82704 | 56026 | 49792 | 50083 |
  | `Channel{Int}(64)` @async | 689 | 663 | 578 | 713 |
  | `Channel{Int}(1024)` @async | 78 | 108 | 103 | 84 |
  | `Channel{Int}(0)` @spawn | 115754 | 36601 | 41223 | 30933 |
  | `Channel{Int}(64)` @spawn | 1840 | 875 | 475 | 1445 |
  | `Channel{Int}(1024)` @spawn | 78 | 349 | 116 | 467 |
  | `Channel{Vector}(0)` x1024 @async | 72 | 47 | 39 | 54 |
  | `Channel{Vector}(4)` x1024 @async | 17.7 | 11.4 | 8.3 | 23.3 |
  | `Channel{Vector}(0)` x1024 @spawn | 64 | 30 | 39 | 51 |
  | `Channel{Vector}(4)` x1024 @spawn | 16.8 | 3.7 | 10.2 | 1.5 |

- Reading: in-process pull (iterator), fold (transducer-like) and push (callbacks) cost the same,
  about 0.3 ns/item once inlined; the push/pull choice is not a throughput question. Any Task boundary
  is 3-5 orders of magnitude slower per item; batching 1024 items per `put!` plus a small buffer brings it to
  1.5-23 ns/item. Caveats: single machine, noisy (spread between runs is large); the `Channel{Int}(1024)`
  rows with n = 5000 mostly measure buffer filling; `-t 2` on 1.13 adds an interactive thread
  (`nthreads(:interactive)=1` in the header), 1.10 does not.

### STR-18: why a per-item handoff costs ~50 us here: the libuv poll, not the task switch
- Same evidence files, calibration lines:
  ```
  1.13.2 -t1: calib: raw yieldto round trip 122.0 ns | calib: Base.process_events() 49697.4 ns/call
  1.10.12 -t1: calib: raw yieldto round trip  95.0 ns | calib: Base.process_events() 39244.0 ns/call
  ```
  A direct `yieldto` round trip is ~0.1 us, but each blocking switch through the scheduler polls libuv,
  ~40-50 us per call on this machine. Whether that cost is typical or specific to this macOS environment
  is **UNVERIFIED** (not measured on Linux). Either way, the design must not do one Task handoff per element.

### STR-19: a virtual-time scheduler for marble tests is small and deterministic
- Command: `for v in release lts; do julia +$v --startup-file=no $S/virtual_time.jl; done`. Output identical
  on both (wall time aside, which is compile time; nothing sleeps):
  ```
  debounce(20)  input  -a-bc----d--e-f|
                output [(60, 'c'), (110, 'd'), (150, 'f'), (150, '|')]  virtual end t=150
  throttle(30)  input  -a-bc----d--e-f|
                output [(10, 'a'), (40, 'c'), (90, 'd'), (120, 'e'), (150, '|')]  virtual end t=150
  deterministic over 100 runs: true
  assertion passed: debounce(20) == [(60,'c'),(110,'d'),(150,'f'),(150,'|')]
  ```
  ~100 lines: a sorted queue of `(time, seq, action)`, `schedule_after!`, `cancel!`, `run!`, a marble
  parser (one char = 10 time units) and `debounce`/`throttle` written against the scheduler. It exposed a
  real semantic choice: at t=30 a's debounce timer and `b` are both due; FIFO-by-`seq` runs `b` first, so `a`
  is never emitted. The ADR must fix same-time ordering (RxJS's exact rule here: **UNVERIFIED**).

## 4. Recommendation

1. **Pull-based core, push/hot as adapters (STR-04, STR-05, STR-07, STR-17).** The core `Stream{T}` is a
   cold description that a consumer pulls from, like fs2/ZIO. In-process, pull, fold and push all cost
   ~0.3 ns/item (STR-17), so pull costs nothing over push and gives backpressure for free. Hot sources
   (Subjects, timers, sockets) enter through an adapter that writes into a bounded buffer with an explicit
   overflow policy (`:block` default, `:drop_oldest`/`:drop_newest`/`:latest` as in Kotlin `buffer`/`conflate`,
   STR-06). Rocket.jl shows the push alternative: no demand signal, unbounded by default (STR-09).
2. **Chunks are the unit of transfer (STR-04, STR-05, STR-17, STR-18).** Pull returns a chunk
   (`AbstractVector{T}`, default target 1024; size a tunable). Element operators (`map`, `filter`, `scan`,
   `take`) run inside a chunk as a ChuiCore transducer (`foldxl` over the chunk), so the transducer
   substrate is reused, not redefined. Only chunk boundaries cross Tasks: per item that is 1.5-23 ns
   instead of 0.5-115 us.
3. **Backpressure = bounded `Channel` blocking at concurrency boundaries (STR-12, STR-17).** Inside one
   task, pull is the backpressure. Where operators need concurrency (`merge`, `mergeMap`, `switchMap`,
   `buffer`/`window` by time, async boundaries), each inner producer is a Task writing chunks into a
   bounded `Channel{Chunk}`; `put!` blocking is the demand signal. A `request(n)` protocol (STR-02) is
   not needed in one process.
4. **Cancellation is scoped and cooperative, tied to the effect runtime (STR-15, STR-16, STR-14, STR-13).**
   Every running stream gets a scope that owns its producer Tasks; leaving the scope (completion, `take`,
   error, outside interrupt) closes their channels and waits for them, so finalizers (`bracket`-style
   acquire/release, as fs2) run. The effect runtime's cancel = close the scope; producers see it at the next
   `put!`/`take!`/`sleep`. `switchMap` = cancel the previous inner scope. Errors travel as values or via
   `bind` (`TaskFailedException`), never via plain iteration of a closed-with-error channel, because that
   is silent on 1.10 (STR-13). Non-yielding loops cannot be interrupted; document it.
5. **Time goes through a scheduler interface with a virtual implementation (STR-19, STR-01, STR-04, STR-05, STR-06).**
   `debounce`, `throttle`, time-based `buffer`/`window`, `retry` with delay and timers ask a scheduler
   for `now()` and `schedule_after!`; production uses `Timer`/`sleep` on Tasks, tests use a virtual clock
   driven by `advance!`/`run!`, plus a marble parser for `cold`/`hot`/`expect`. Specify same-time ordering.
6. **ChuiFrames `Source` (STR-17, STR-16).** A `Stream{T}` of row chunks (or a stream of table batches)
   exposes `Base.iterate` returning one batch per step, `IteratorSize = SizeUnknown()` so unbounded streams
   are fine; a scoped `withbatches(f, stream)` (or `open(stream) do it ... end`) guarantees cleanup when the
   frame consumer stops early. A plain iterator over batches is what the ChuiFrames adapter needs; the
   batch type is the open question for the cross-package contract.
7. **Dependencies: none.** Base `Channel`, `Task`, `Timer`, `Threads` and ChuiCore's transducers cover
   the design; the virtual scheduler needs only a priority queue (a sorted `Vector` in STR-19; a binary
   heap is ~40 lines, so DataStructures.jl is not needed). Rocket.jl (light, maintained) is a reference
   and a possible weak-dependency bridge (`ext/`), not a base (STR-09). Transducers.jl (42 packages) is
   ruled out (STR-11).

## Also noticed
- `Base.n_avail` on a full channel counts a blocked putter (STR-12).
- On 1.13 `-t 2` yields 2 default threads plus 1 interactive thread; on 1.10 it yields 2 default threads only (STR-17 headers).
- A first throughput draft timed 0.0 ns/item: the pure pipelines were dead-code eliminated when the result
  was discarded. The final script feeds results into a global `SINK` (`$S/throughput.jl`).
