# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase3-effects`, cut from `main` at `dc1882c` (phases 1 and 2 merged). It is
  **not merged**: it waits for the lead's review and merge.
- **Remote:** none pushed from this lane.
- **Phase:** **phase 3 (Reader/Writer/State, the effect runtime, its adapters) is implemented**
  on the branch.
  - Spec: `docs/superpowers/specs/2026-10-20-phase3-effects-design.md` (decisions ADRs 0002,
    0006 and 0007 leave open, and the proposed names, §1). Plan:
    `docs/superpowers/plans/2026-10-20-phase3-effects.md`.
  - ADR-0007 (**Proposed**): Reader/Writer/State are erased node trees with one declared
    parameter (`Reader{R}`, `Writer{W}`, `State{S}`), run by an explicit-stack interpreter.
    Measured (`rws-*`, `rwsdeep-*` evidence), critiqued (critic: ACCEPT WITH FIXES; fixes applied).
  - `src/rws.jl`, `reader.jl`, `writer.jl`, `state.jl` (sub-lane `rws`, copied in as commit
    `267bc6c`); `src/effect/` (types, context, interpreter, fiber, api, clock, combinators,
    schedule, adapters).
  - Tests: unit (`test_effect.jl`, `test_reader/writer/state.jl`), laws (`test/laws/
    test_laws_effect.jl`, `test_laws_rws.jl`), properties with planted violations
    (`test_effect_props.jl`), leak stress (`test_effect_stress.jl`, `:slow`).
- **Dependencies:** `Compat = "4.10"`, **`ScopedValues = "1.6"` (new, ADR-0005)**. ChuiCore is
  still unreleased and is not a dependency.
- **Not built (phase 4 or later):** streams, `Queue`, `fromchannel`/`tochannel`, futures,
  semaphores, `jittered` schedules (needs a random source; `Random` is not a dependency).
- **Evidence files:** `.lanes/evidence/` (gitignored), keyed to the lane's commits; the lane's
  report lists the commands and counts.

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| `phase3-effects` | types-p3 (lead-dispatched) | `src/**`, `ext/**`, `test/**`, `Project.toml`, `docs/**`, `benchmark/**`, `HANDOFF.md`, `changelog.d/phase3-effects.md`, `.gitignore` | implemented; reviewer FINAL ACCEPT at `37ec1ad`; waiting for the lead's merge | SendMessage to the lead, 2026-10-20 |

Follow-ups the reviewer left as NITs (not fixed on this branch): `_race`/`_zippar` should `_stop!`
their children in a `try/finally`, so a ^C escaping a masked wait cannot strand them (N-a); the
stress test's test-mode section runs `runtest` in a non-sticky task, and should use a sticky one (N-b).

## Decisions waiting (for the lead / the user at the phase-3 ★)

1. **ADR-0007** (Reader/Writer/State encoding): Proposed; accept or amend.
2. **Names** (spec §1): every new export and public name. Notable choices: `andthen` as the
   public bind (the `Upstream.chain` stand-in stays internal); `succeeded` (not `issuccess`,
   which LinearAlgebra exports); `listening`/`withreader` (avoid `Sockets.listen` and the
   `local` keyword); `getstate`/`putstate` (avoid `Base.get`).
3. **Semantics to confirm:** a child failure fails its scope even when the parent awaited the
   child (Kotlin semantics; `race`/`timeout`/`zippar` use unsupervised children). `timeout`'s
   `none(A)` uses the advisory `A`. Inside a masked region, the hidden children of
   `race`/`timeout`/`zippar`/`fromtask(f)` are detached from the fiber's cancellation (so they
   work in releases); a user `fork` there is still cancelled with its scope.
   **Test mode and foreign tasks:** virtual time is frozen while a `fromtask(t::Task)` runs, so
   `timeout(fromtask(t), d)` never expires on a slow `t` under `runtest`; `advance!`/`runtest`
   throw after the wall-clock timeout instead, and an abandoned `t` keeps test mode busy (this
   changes how ADR-0013's orphan rule looks under `runtest`).
4. Carried over: the `docs/CHECK_COVERAGE.md` row for the ChuiCore grep test, and requests R1–R5
   (ADR-0004 §7), still with the coordinator.

## Checks NOT run, and why

- Julia 1.14 (alpha) and 1.12: no runnable binaries locally.
- `ci.jl contracts`: skips (waiting): `test/contracts/upstreams.toml` has no ChuiCore URL.
- GitHub workflows: no remote from this lane.
- Benchmarks were added to `benchmark/` but not run as a suite on an idle machine.
- **Stale `origin/main` (the lead's).** `scripts/lane audit` and `dod.jl --base main` compare
  against `origin/main` until the lead pushes; `dod.jl --base dc1882c` gives this branch's
  true diff.

## Next action

After the lead merges: phase 4 (futures and streams on `Queue`, `Scope`, the clock and test
mode), in a new lane. At ChuiCore's first snapshot: the switch-over of ADR-0004 §3.
