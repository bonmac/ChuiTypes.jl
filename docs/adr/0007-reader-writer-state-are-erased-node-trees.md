# ADR-0007: Reader, Writer and State are erased node trees with a declared parameter, run by a pure trampoline

- **Status:** Accepted (2026-10-20, user at the ChuiTypes phase-3 ★). Also decided there: the
  phase-3 names as proposed (`andthen` the public bind), a child failure fails its scope even when
  awaited, combinator helpers detached from cancellation inside masked regions, and test-mode virtual
  time frozen while a plain `Task` runs.
- **Date:** 2026-10-20
- **Deciders:** the user, at the next ★ checkpoint (via the lead)
- **Scope:** ChuiTypes.jl

## Context

ADR-0001 §8 deferred the encoding of `Reader`, `Writer` and `State` to phase 3, under three
constraints: no public type parameter derived from inference and no assertion against an inferred
type; stack safety for deep binds; laws checked by running both sides on sample inputs. It named
three candidates: closure-specialised structs (SUM-12), an erased callable with a result type the
user declares, and the effect trampoline (ADR-0002 §1).

Measurements (script `docs/research/scripts/encoding/rws_encodings.jl`; evidence `rws-113`,
`rws-110`, `rwsdeep-110`, `rwsdeep-113`, all at `f87a3fa`, in `.lanes/evidence/`). The workload is a counter: `get`, then
`put(s + 1)`, repeated; "left" nests binds as `bind(bind(bind(m, k), k), k)`, "right" as
`bind(m, x -> bind(…))`.

- **Closure struct `CState{F}`** (candidate A). Here `return_types` stays concrete to depth 4 for
  `x -> cpure(x + 1)` chains on both versions, unlike SUM-12's shape (which lost inference at depth
  3); inference depends on the closure shape. Each bind nests the closure *type*, so a chain built
  in a loop compiles one new type per bind. On 1.10.12 (`rwsdeep-110`, build and first run timed
  separately) building is cheap (0.38 s at depth 10^4) but the first run, which compiles the
  nested types, takes 0.16 s at depth 100, 8.71 s at 1000, 35.65 s at 2000, 137.45 s at 4000 and
  941.69 s at 10^4, printing "Internal error: stack overflow in type inference" 12 times from
  depth 4000 on. On 1.13.2 (`rwsdeep-113`) the first runs took 0.12 s, 9.11 s, 37.92 s and
  299.16 s at depths 100 to 4000; the depth-10^4 run had not finished when it was killed (signal
  15) after 2061 s in total. Its header says `exit: 0` because `scripts/evidence.jl` records the
  exit code but not the signal (a draft request in the phase-3 report). A chain built from data (a loop, a
  `foldl` over a vector) is the normal case for Writer and State, so A is unusable there,
  whatever its inference.
- **Erased node tree with a declared state type** (candidate B: the "erased callable" candidate,
  made a data tree so that it can be trampolined). `EState{S}` wraps an internal node; a run loop
  keeps an explicit continuation stack. Two node layouts were measured: abstract node structs
  (B1) and one concrete node with a `UInt8` tag (B2).
  - `return_types(run, (State{Int}, Int))` is `Tuple{Any, Int64}` on both versions: the state
    stays concrete through the declared `S`; the result `a` is `Any`.
  - Depth 10^6, left- and right-nested, both layouts, both versions: final state `1000000`, no
    overflow.
  - Run cost, 10^5 increments, best of 5: B1 18.7 / 20.2 ns per bind, B2 20.0 / 19.4 ns per bind
    (1.13.2 / 1.10.12). The two layouts are within run-to-run noise (an earlier dirty-tree run
    had B2 ahead on both versions). 82–83 B are allocated per increment, which is two binds, so
    about 41 B per bind (the closures and nodes the continuations build). Building the chain
    costs 3.3 / 2.6 ns per increment for B2 (results go to a global sink, so the loop is not
    optimised away).
- **Writer's cost is the monoid's.** The run threads one accumulator, `acc = combine(acc, w)` per
  `tell`, in execution order. With an `Int` sum: 30–35 ns per tell. With a `Vector` log and `vcat`,
  which copies the log on every tell: 429–1086 ns per tell at 10^3–10^4 tells, growing with the
  log (quadratic in total). With an in-place `append!` into an accumulator the run owns: 27–32 ns
  per tell (`rws-113`, `rws-110`).
- **The effect trampoline** (candidate C). Reader, Writer and State are pure: none needs a Task, a
  clock or cancellation. On C, every run would still go through the runtime's cancellation
  checks, its `ScopedValue` bridge and its `Exit` machinery, and a pure `State` could not run
  without the runtime. The speed gap is smaller: an interpreted effect step costs 25–70 ns
  (ADR-0002 §1, EFF-12), 1.25–3.5× B's step.

## Decision

1. **`Reader{R}`, `Writer{W}` and `State{S}` are concrete structs with one public parameter,
   which the user declares**, never one derived from inference:
   - `R` is the environment type, `W` the log type, `S` the state type.
   - Each wraps one internal, erased node (B2's layout: one concrete node struct with a tag and
     untyped payload fields). The nodes are not public. The node is a `mutable struct` whose
     fields are all `const`: never mutated, but compared and hashed by identity, because `===`
     and `hash` on an immutable node recurse through the tree and overflow the stack on two
     separately built 10^6-node programs (found by the implementing sub-lane, both versions).
   - The success type `A` is **not a parameter**. Results come back as `Any` unless the caller
     asserts a type it declares: `runstate(m, s0, T)`, `runreader(m, r, T)`,
     `runwriter(m, mon, T)` assert `a::T` (ADR-0002 §1's `run(eff, T)` rule).
2. **Each type is run by its own small loop with an explicit continuation stack** (one shared
   internal interpreter over the three node sets is allowed). The loop must not recurse on bind
   depth, so left- and right-nested chains of 10^6 binds run on both versions (tested at 10^5 in
   the unit suite, 10^6 in a `:slow` item).
3. **The parameter is fixed where a value is built, and the run keeps it concrete.**
   - Primitives that need the parameter take it: `getstate(S)`, `putstate(S, x)` (which stores
     `convert(S, x)` when the value is built, so a bad `x` throws there), `modifystate(f, S)`,
     `ask(R)`, `asks(f, R)`. `putstate(x)` and `tell(w)` use `typeof(x)` and `typeof(w)`.
   - The run's state slot is an `S`, its environment an `R` and its log accumulator a `W`.
   - **Writer** starts from `neutral(mon)` once per run (a fresh value the run owns) and threads
     `acc = combine(mon, acc, w)` (`Upstream.combine`, ADR-0004 §2; no default monoid) in
     execution order. Left- and right-nested chains therefore give the same log, and the Monad
     laws rest on associativity. A monoid that combines into its first argument in place costs
     linear time; a copying one costs quadratic time, and the docstring says so.
   - **Scoped operations are frames, not nested runs.** Reader's `local` (`withreader(f, m)`) and
     Writer's `listen`/`censor` (`listening(m)`, `censor(f, m)`) push a restore frame onto the
     same explicit stack, so nesting them 10^5 deep is stack-safe (tested). The names avoid the
     keyword `local`, `Base.get` and `Sockets.listen`.
4. **Instances:** Functor, Applicative and Monad for all three, through the `Upstream`
   stand-ins (`fmap`, `pure(tag, x)`, `ap`, `chain`) and `Base.map`; the public bind is
   `andthen(k, m)`. Tags carry the declared parameter (`ReaderTag{R}`, `WriterTag{W}`,
   `StateTag{S}`). If a continuation of a `State{S}` returns anything but a `State{S}` (for
   example `putstate(0x01)`, a `State{UInt8}`, inside a `State{Int}`), the run throws an
   `ArgumentError` naming both types. The same holds for Reader and Writer. Values are immutable
   and can be shared across threads; each run owns its stack.
5. **Equality is extensional and is not defined on the values.** `==`/`isequal`/`hash` fall back
   to identity; law tests compare by running both sides on sample inputs (environments, initial
   states, monoids), per ADR-0001 §8.
6. **Not built on `Effect`.** They are pure and run without Tasks; lifting one into an `Effect`
   is `sync(() -> runstate(m, s0))`. A later ADR may add `Effect`-native forms (for example a
   `State` held in a fiber-local reference) if phase 5 finds a need.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Closure struct `State{F}` (A) | Compiles one type per bind: the first run of a loop-built chain of 10^4 binds took 941.69 s on 1.10.12 (`rwsdeep-110`) and had not finished after more than 1700 s on 1.13.2 (`rwsdeep-113`); inference depends on the closure shape (SUM-12 vs `rws-113`). |
| `A` as a type parameter from `promote_op` | ADR-0001 §8 and `polate-*`: stale inference throws on correct programs. |
| `A` as a parameter the user declares on every constructor | Every `pure`/`map`/`chain` would need an extra type argument; the `run(m, s, T)` assertion gives the same guarantee at one place. |
| Build them on `Effect` (C) | A pure `State` would need the runtime (Tasks, cancellation, `Exit`) to run; also 1.25–3.5× B's step cost. |
| Abstract node types (B1) | Same speed as B2 within noise. B2 is chosen because one concrete node field avoids a dynamic type check of the node on every step. |
| Value equality on the structs | Two programs are equal only extensionally; comparing node trees would make `map(identity, m) != m`. |

## Consequences

- New exported names (proposed at the phase-3 ★, checked by CT-003): `Reader`, `Writer`, `State`,
  their constructors and run functions (spec `docs/superpowers/specs/2026-10-20-phase3-effects-design.md` §2).
- Results are `Any`-typed unless asserted. Code that needs a concrete result passes `T`.
- About 20 ns and 41 B per bind: fine for configuration, logging and parser-like code; a hot
  numeric loop should not be written as a `State` chain.
- Law kits compare with an `eq` that runs both sides (`test/laws/`).

## Verification

- Evidence `rws-113`, `rws-110`, `rwsdeep-110`, `rwsdeep-113` (clean tree at `f87a3fa`), in
  `.lanes/evidence/`, produced by `scripts/evidence.jl` on 1.13.2 and 1.10.12; script in `docs/research/scripts/encoding/`
  (Runic-formatted after the runs, formatting only). Evidence files are gitignored and local.
- SUM-12 (`docs/research/sum-types.md`).
- UNVERIFIED: Reader was not measured separately (it shares State's shape); benchmarks on an
  idle machine (other lanes' Julia processes ran during every measurement).

## Revisit when

- Phase 5 profiling finds a `Reader`/`Writer`/`State` chain on a hot path.
- Julia gains a cheap way to keep closure chains from specialising per bind.
