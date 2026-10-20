# ADR-0007: Reader, Writer and State are erased node trees with a declared parameter, run by a pure trampoline

- **Status:** Proposed (phase 3; goes to the user at the phase-3 report)
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
`rws-110`, `rwsdeep-113` in `.lanes/evidence/`). The workload is a counter: `get`, then
`put(s + 1)`, repeated; "left" nests binds as `bind(bind(bind(m, k), k), k)`, "right" as
`bind(m, x -> bind(…))`.

- **Closure struct `CState{F}`** (candidate A). Here `return_types` stays concrete to depth 4 for
  `x -> cpure(x + 1)` chains on both versions, unlike SUM-12's shape (which lost inference at depth
  3); inference depends on the closure shape. Each bind nests the closure *type*, so a chain built
  in a loop compiles one new type per bind. Left-nested depth 1000 ran (`rwsdeep-113`: `1000`);
  depth 10^4 had not finished after 610 s and was killed (signal 15) while still compiling. A
  chain built from data (a loop, a `foldl` over a vector) is the normal case for Writer and
  State, so A is unusable there, whatever its inference.
- **Erased node tree with a declared state type** (candidate B: the "erased callable" candidate,
  made a data tree so that it can be trampolined). `EState{S}` wraps an internal node; a run loop
  keeps an explicit continuation stack. Two node layouts were measured: abstract node structs
  (B1) and one concrete node with a `UInt8` tag (B2).
  - `return_types(run, (State{Int}, Int))` is `Tuple{Any, Int64}` on both versions: the state
    stays concrete through the declared `S`; the result `a` is `Any`.
  - Depth 10^6, left- and right-nested, both layouts, both versions: final state `1000000`, no
    overflow.
  - Run cost, 10^5 increments, best of 5: B1 23.1 / 22.4 ns per bind, B2 21.6 / 19.3 ns per bind
    (1.13.2 / 1.10.12); 82–83 B allocated per increment (the closures and nodes the
    continuations build). Building the chain costs about 3 ns per increment on 1.13.2.
- **The effect trampoline** (candidate C). An interpreted effect step costs 25–70 ns (ADR-0002
  §1, EFF-12) and every run goes through cancellation checks, a `ScopedValue` bridge and the
  `Exit` machinery. Reader, Writer and State are pure; none needs a Task, a clock or cancellation.

## Decision

1. **`Reader{R}`, `Writer{W}` and `State{S}` are concrete structs with one public parameter,
   which the user declares**, never one derived from inference:
   - `R` is the environment type, `W` the log type, `S` the state type.
   - Each wraps one internal, erased node (B2's layout: one concrete node struct with a tag and
     untyped payload fields). The nodes are not public.
   - The success type `A` is **not a parameter**. Results come back as `Any` unless the caller
     asserts a type it declares: `runstate(m, s0, T)`, `runreader(m, r, T)`,
     `runwriter(m, mon, T)` assert `a::T` (ADR-0002 §1's `run(eff, T)` rule).
2. **Each type is run by its own small loop with an explicit continuation stack** (one shared
   internal interpreter over the three node sets is allowed). The loop must not recurse on bind
   depth, so left- and right-nested chains of 10^6 binds run on both versions (tested at 10^5 in
   the unit suite, 10^6 in a `:slow` item).
3. **The run functions keep the declared parameter concrete:** the state slot is typed `S` (a
   `put` of a non-`S` value is converted with `convert(S, x)`, or throws), the environment is an
   `R`, and the log accumulator is a `W`, combined with the caller's monoid instance through
   `Upstream.combine` (ADR-0004 §2; no default monoid).
4. **Instances:** Functor, Applicative and Monad for all three, through the `Upstream`
   stand-ins (`fmap`, `pure(tag, x)`, `ap`, `chain`) and `Base.map`. Tags carry the declared
   parameter (`ReaderTag{R}`, `WriterTag{W}`, `StateTag{S}`). Binding a `State{S}` continuation
   that returns a `State{S2}` with `S2 !== S` throws an `ArgumentError` at run time.
5. **Equality is extensional and is not defined on the values.** `==`/`isequal`/`hash` fall back
   to identity; law tests compare by running both sides on sample inputs (environments, initial
   states, monoids), per ADR-0001 §8.
6. **Not built on `Effect`.** They are pure and run without Tasks; lifting one into an `Effect`
   is `sync(() -> runstate(m, s0))`. A later ADR may add `Effect`-native forms (for example a
   `State` held in a fiber-local reference) if phase 5 finds a need.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Closure struct `State{F}` (A) | Compiles one type per bind: a loop-built chain of 10^4 binds did not finish in 610 s (`rwsdeep-113`); inference depends on the closure shape (SUM-12 vs `rws-113`). |
| `A` as a type parameter from `promote_op` | ADR-0001 §8 and `polate-*`: stale inference throws on correct programs. |
| `A` as a parameter the user declares on every constructor | Every `pure`/`map`/`chain` would need an extra type argument; the `run(m, s, T)` assertion gives the same guarantee at one place. |
| Build them on `Effect` (C) | 25–70 ns per step plus Task, cancellation and `Exit` overhead for pure code; a pure `State` would need the runtime to run. |
| Abstract node types (B1) | Measured slightly slower than the tagged node (B2) on both versions; either is acceptable, B2 is chosen for the speed. |
| Value equality on the structs | Two programs are equal only extensionally; comparing node trees would make `map(identity, m) != m`. |

## Consequences

- New exported names (proposed at the phase-3 ★, checked by CT-003): `Reader`, `Writer`, `State`,
  their constructors and run functions (spec `docs/superpowers/specs/2026-10-20-phase3-effects-design.md` §2).
- Results are `Any`-typed unless asserted. Code that needs a concrete result passes `T`.
- About 20 ns and 80 B per bind: fine for configuration, logging and parser-like code; a hot
  numeric loop should not be written as a `State` chain.
- Law kits compare with an `eq` that runs both sides (`test/laws/`).

## Verification

- Evidence `rws-113`, `rws-110`, `rwsdeep-113` (`.lanes/evidence/`, produced by
  `scripts/evidence.jl` on 1.13.2 and 1.10.12), script in `docs/research/scripts/encoding/`.
- SUM-12 (`docs/research/sum-types.md`).
- UNVERIFIED: the closure depth-10^4 run on 1.10.12 (not repeated after 1.13.2 took over 600 s);
  Reader and Writer were not measured separately (they share State's shape); benchmarks on an
  idle machine.

## Revisit when

- Phase 5 profiling finds a `Reader`/`Writer`/`State` chain on a hot path.
- Julia gains a cheap way to keep closure chains from specialising per bind.
