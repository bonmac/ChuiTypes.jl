# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- Branch / last commit: `main`, the initial commit `chore: scaffold ChuiTypes.jl from factory 0.2.1`.
- Phase and current task: **scaffolded; phase 1 (Research and ADRs) not started.** See
  `docs/agent/BRIEF.md` § Phases.
- **ChuiCore is not released yet, so there is no upstream dependency.** `Project.toml` has no
  `[deps]`. `test/contracts/upstreams.toml` names ChuiCore without a URL, and `USED.md` lists no IDs.
  The ChuiCore contract copy (`test/contracts/chui-core.md`, v0 DRAFT, coordinator commit 275e879)
  is vendored for `scripts/contract_usage.jl`.
- Factory 0.2.1, package profile (`.factory-version`).
- ★-dependent defaults, pending the user's L0 decisions:
  - version `0.0.1` (ADR-0004 `0.0.x` snapshots);
  - `julia = "1.10"` (ADR-0006);
  - TestItemRunner, plus a Runic `format` job from the factory (ADR-0007);
  - MIT license (ADR-0011).

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| (none) | | | | |

Closure proof: no lanes were opened; the scaffold was written directly on `main` by the
`scaffold-types` lane of the coordinator.

## Evidence

`subagent_mode: actual` (one lane, `scaffold-types`, run by the coordinator lead).

| Command | Result |
|---|---|
| `julia --project=. -e 'using Pkg; Pkg.test()'` (1.13.2) | `ChuiTypes | 3 3`, tests passed |
| `julia +lts --project=. -e 'using Pkg; Pkg.test()'` (1.10.12) | `ChuiTypes | 3 3`, tests passed |
| `julia scripts/ci.jl quality` (1.13.2) | 17/17 passed (Aqua, ExplicitImports incl. `*_are_public`) |
| `Pkg.test(test_args=["quality"])` on 1.10.12 | 15/15 passed (`*_are_public` gated off below 1.11) |
| `julia scripts/ci.jl test` | `ci.jl test: OK` |
| `julia scripts/ci.jl jet` (1.13.2, JET 0.12.3) | `ci.jl jet: OK` |
| `julia scripts/ci.jl docs` (Documenter 1.19.0) | `ci.jl docs: OK`; `objects.inv` written |
| `julia scripts/gen.jl --check` | `OK (30 files)` |
| `julia scripts/contract_usage.jl` | `OK (0 IDs listed, 0 tested, 0 upstream names used; 0 warnings)` |
| `julia scripts/test/runtests.jl` | `factory | 631 631` |
| `uvx --from actionlint-py actionlint .github/workflows/*.yml` | exit 0, no findings |
| `julia scripts/ratchet.jl` | **FAILED**: managed `bash_guard.sh` has 210 lines > 150 (factory bug) |
| `julia scripts/check_docs.jl` | `OK (41 files, 4 excluded by [check_docs] exclude)` |
| fresh clone + `Pkg.instantiate(); Pkg.test()` | passed (see the scaffold report) |

## Checks NOT run, and why

- GitHub workflows (`CI`, `Docs`, `Contracts`, `Benchmark`, `Guards`, `CompatHelper`, `TagBot`):
  they need a GitHub remote, which waits for the user's ★. Only actionlint ran.
- `ci.jl contracts`: it skips because there are no upstream URLs; ChuiCore is unreleased.
- `ci.jl format` (Runic): the formatter is a pending ★ (ADR-0007).
- `ci.jl bench`, `ci.jl coverage`: there is no benchmark suite and no `lcov.info` yet.
- `ci.jl dod`: there is no PR and no merge base.

## Blockers and decisions waiting

- ★ L0 decisions: versioning `0.0.x` (ADR-0004), Julia floor (ADR-0006), formatter (ADR-0007),
  license, benchmarks and coverage (ADR-0011).
- Factory bugs reported to the lead (factory 0.2.1):
  - `ratchet.jl` fails because of the managed `bash_guard.sh` size;
  - `ci.jl docs`/`jet` write an absolute `[sources]` path into the committed `Project.toml`;
  - the seeded `.gitignore` misses `/test/jet/Manifest*.toml`;
  - the package profile seeds no `[check_docs] exclude` for the verbatim copies
    (`docs/agent/*`, `test/contracts/*.md`). Fixed here by a user-authorized T3 edit of
    `.agents/factory.toml`.
- ChuiCore's first release: needed before any `[deps]` entry or contract test.

## Next action

- After the ★ decisions: phase 1 of the brief. Write ADRs on the type-stable encoding, the
  effect runtime (fibers or `Task`s, cancellation) and the stream design (push or pull,
  backpressure), then report to the lead before implementing.
