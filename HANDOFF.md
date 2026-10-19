# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase1-research`, cut from `main` at `db74452` (factory 0.2.5 sync). It is
  **not merged**: it waits for the lead's review and merge.
- **Remote:** none pushed from this lane.
- **Phase:** **phase 1 (Research and ADRs) is done; the ★ was answered on 2026-10-20** (below).
- **What the branch adds** (spec: `docs/superpowers/specs/2026-10-20-phase1-research-design.md`):
  - three research notes in `docs/research/` (SUM-, EFF- and STR- entries, run on 1.13.2 and
    1.10.12);
  - six ADRs in `docs/adr/` (0001–0006), Accepted at the ★;
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
| `phase1-research` | types-p1 (lead-dispatched) | `docs/adr/**`, `docs/research/**`, `docs/superpowers/**`, `HANDOFF.md`, `changelog.d/phase1-research.md` | ★ answered, ADRs accepted; waiting for the lead's merge | SendMessage to the lead, 2026-10-20 |

Sub-agents of this lane, all closed after reporting: 3 researchers (sum types, effects, streams)
and 2 critics, each running 3 rounds.
- The critic on ADR-0002/0003/0006 and the spec started at 4 blockers and 14 should-fix, then
  1 blocker and 4 should-fix, then **0/0, accept**.
- The critic on ADR-0001/0004/0005 started at 2 blockers and 9 should-fix, then 0 blockers and
  2 should-fix, then **0/0, accept**.

The experiment scripts are kept in `docs/research/scripts/`.

## Decisions (★ answered by the user, 2026-10-20; all recommendations accepted)

1. **ADRs 0001–0006 accepted** as the design for phases 2–4.
2. **Contract conflicts C1/C2/C3:** `chui-types.md` obligation 2 is amended through a contract
   ADR in the coordinator, using ADR-0006 "Consequences" wording. The coordinator lane writes
   it; applying the contract text needs the user's T3 approval. **Pending.**
3. **Names accepted as proposed:** `Option`/`Either` with no aliases; `Effect{E,A}` with no
   environment parameter; `run` as a `Base.run` method; `interrupt!` plus `await`;
   `this`/`that`/`both` public (`@compat public`), not exported.
4. **Supposition on 1.10:** decided for all packages; ecosystem ADR-0007 §2 is amended to require
   `@check record=false` plus `@test`.
5. **ChuiCore requests R1–R5** (ADR-0004 §7) go into the coordinator's `requests/`, written by
   the coordinator lane. Registering R4 is an outward action and returns to the user. R1 is
   partly settled by ChuiCore ADR-0001 (accepted, ChuiCore main `8082735`): `combine(m, a, b)` on
   an instance value, fresh `neutral(m)`, constructor classes as Holy traits (`pure(tag, x)`);
   the stand-ins must follow it.

## Checks NOT run, and why

- `ci.jl test`/`quality`/`jet`: this phase adds no code (docs only).
- Julia 1.14 (alpha) and 1.12: no runnable binaries locally. EFF-02 is source-only.
- GitHub workflows: no remote from this lane.

## Next action

Once the lead merges this branch: phase 2 ("Core data types, plus laws") per ADR-0001 and
ADR-0004, in a new lane.
