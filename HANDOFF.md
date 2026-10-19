# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase1-research`, cut from `main` at `db74452` (factory 0.2.5 sync). It is
  **not merged**: this is the phase-1 ★ checkpoint.
- **Remote:** none pushed from this lane.
- **Phase:** **phase 1 (Research and ADRs) is done and waits at ★.** Per `docs/agent/BRIEF.md`
  § Phases, phase 2 must not start until the user answers the questions below.
- **What the branch adds** (spec: `docs/superpowers/specs/2026-10-20-phase1-research-design.md`):
  - three research notes in `docs/research/` (SUM-, EFF- and STR- entries, run on 1.13.2 and
    1.10.12);
  - six Proposed ADRs in `docs/adr/` (0001–0006);
  - `changelog.d/phase1-research.md`.

  No code, `Project.toml` or contract changes.
- **ChuiCore is still unreleased.** `Project.toml` has no `[deps]`. ADR-0004 puts every ChuiCore
  use behind `ChuiTypes.Upstream`, and ADR-0005 adds ChuiCore at its first `0.0.x` snapshot.
- **Unchanged since the scaffold:**
  - the L0 defaults: `0.0.1`, `julia = "1.10"`, TestItemRunner plus Runic, MIT;
  - the lane cap of 6;
  - `:contract` items run only in `test/contracts/`.
- **Evidence files** are in `.lanes/evidence/` (gitignored), keyed to `db74452`: `sum-*`,
  `opt2*`, `effenc-*`, `eff-bench-*`, `streams-tp-*`, `names-*`, `ctor-names-*`,
  `runtime-names-*`.

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| `phase1-research` | types-p1 (lead-dispatched) | `docs/adr/**`, `docs/research/**`, `docs/superpowers/**`, `HANDOFF.md`, `changelog.d/phase1-research.md` | committed on branch, waiting at ★ | SendMessage to the lead, 2026-10-20 |

Sub-agents of this lane, all closed after reporting: 3 researchers (sum types, effects, streams)
and 2 critics, each running 3 rounds.
- The critic on ADR-0002/0003/0006 and the spec started at 4 blockers and 14 should-fix, then
  1 blocker and 4 should-fix, then **0/0, accept**.
- The critic on ADR-0001/0004/0005 started at 2 blockers and 9 should-fix, then 0 blockers and
  2 should-fix, then **0/0, accept**.

The experiment scripts are kept in `docs/research/scripts/`.

## Decisions waiting (★, for the user via the lead)

1. **Accept ADRs 0001–0006** as the design for phases 2–4. Recommended: accept.
2. **Contract conflicts C1/C2/C3** (spec, "Contract consistency"). Recommended: amend
   `chui-types.md` obligation 2 through a contract ADR in the root repo, using the wording in
   ADR-0006 "Consequences".
3. **Names.** `Option`/`Either`, no `Maybe`/`Result` aliases; `Effect{E,A}` with no environment
   type parameter; `run` as a `Base.run` method; `delay`/`clocktime`; `interrupt!` plus
   `await`, since `interrupt` is Distributed's; whether to export the
   `These` constructors `this`/`that`/`both`. Recommended: as proposed, with `this`/`that`/`both`
   **not exported**, but marked `@compat public` and called as `ChuiTypes.both(a, b)`, because an
   exported `both` blocks a later top-level `both = …` on 1.10/1.11 (E-24 behaviour).
4. **Supposition on 1.10.** Use the `@check record=false` plus `@test` workaround until root
   ADR-0007 §2 is amended. Recommended: yes.
5. **ChuiCore requests R1–R5** (ADR-0004 §7). Recommended: the lead files them before ChuiCore's
   first snapshot.

## Checks NOT run, and why

- `ci.jl test`/`quality`/`jet`: this phase adds no code (docs only).
- Julia 1.14 (alpha) and 1.12: no runnable binaries locally. EFF-02 is source-only.
- GitHub workflows: no remote from this lane.

## Next action

After ★: phase 2 (core data types plus local law tests) per ADR-0001 and ADR-0004, in a new lane.
