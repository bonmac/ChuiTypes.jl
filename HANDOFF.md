# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase2-datatypes`, cut from `main` at `455c085` (phase 1 accepted and
  merged). It is **not merged**: it waits for the lead's review and merge.
- **Remote:** none pushed from this lane.
- **Phase:** **phase 2 (core data types, plus laws) is implemented** on the branch.
  - Spec: `docs/superpowers/specs/2026-10-20-phase2-datatypes-design.md` (decisions the ADRs
    leave open). Plan: `docs/superpowers/plans/2026-10-20-phase2-datatypes.md`.
  - Types (ADR-0001): `Option`, `Either`, `Validation`, `These`, `NonEmpty`, `LazyList`, one
    file each in `src/`.
  - `src/upstream.jl`: the `ChuiTypes.Upstream` stand-ins (ADR-0004), mirroring ChuiCore
    ADR-0001 (`combine(m, a, b)`, fresh `neutral(m)`, `pure(tag, x)`). Not exported, not public.
  - Law kits in `test/laws/kits.jl` (`@check record=false db=false` plus `@test`), law tests for
    every ADR-0001 §10 instance, one planted violation per law (runs on 1.10).
  - `benchmark/`: a `SUITE` for the four zero-allocation chains of ADR-0001 §11.
- **Dependencies:** `Compat = "4.10"` (for `@compat public`, ADR-0005 §1). ChuiCore is still
  unreleased and is not a dependency. Test-only: Supposition `0.3`, plus the stdlibs the CT-003
  test loads.
- **Unchanged:** the L0 defaults (`0.0.1`, `julia = "1.10"`, TestItemRunner plus Runic, MIT);
  the lane cap of 6; `:contract` items run only in `test/contracts/`; `USED.md` lists no ChuiCore
  IDs (nothing from ChuiCore is used yet).
- **Evidence files:** `.lanes/evidence/` (gitignored), keyed to the lane's commits; the lead's
  report lists the commands and counts.

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| `phase2-datatypes` | types-p2 (lead-dispatched) | `src/**`, `ext/**`, `test/**`, `Project.toml`, `docs/**`, `benchmark/**`, `HANDOFF.md`, `changelog.d/phase2-datatypes.md` | implemented; reviewer pass pending | SendMessage to the lead, 2026-10-20 |

## Decisions waiting (for the lead)

1. **`docs/CHECK_COVERAGE.md` row for the ChuiCore grep test** (ADR-0004 §1). The file is
   generated from `.agents/checks.local.toml`, outside this lane's scope. Blind spots to list:
   names built at run time (`getfield(Main, Symbol(...))`, `eval`), modules reached through
   `Base.loaded_modules`.
2. **Requests R1–R5** (ADR-0004 §7) are still to be filed by the coordinator. R1 now has
   concrete proposals: `chain` (bind), `ap`, `alt`, `zeroalt(tag, T)`, `bimap`, tags that carry
   the fixed parameters (`EitherTag{L}()`), and `default_monoid` for `These`.

## Checks NOT run, and why

- Julia 1.14 (alpha) and 1.12: no runnable binaries locally.
- `ci.jl contracts`: skips (waiting): `test/contracts/upstreams.toml` has no ChuiCore URL.
- GitHub workflows: no remote from this lane.

## Next action

Once the lead merges this branch: phase 3 (Reader/Writer/State encoding ADR, the effect runtime,
`sync(f)`), in a new lane. At ChuiCore's first snapshot: the switch-over of ADR-0004 §3.
