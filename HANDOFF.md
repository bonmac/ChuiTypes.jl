# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- Branch / last commit: `main`, `fix: align runtests and jet compat with ChuiCore, re-pin
  coordinator provenance` (after the factory 0.2.4 sync and the scaffold commit).
- Remote: **none yet.** The public repo `bonmac/ChuiTypes.jl` is approved by the user and is
  about to be created by the lead; nothing has been pushed.
- Phase and current task: **scaffolded; phase 1 (Research and ADRs) not started.** See
  `docs/agent/BRIEF.md` § Phases.
- **ChuiCore is not released yet, so there is no upstream dependency.** `Project.toml` has no
  `[deps]`. `test/contracts/upstreams.toml` names ChuiCore without a URL, and `USED.md` lists no IDs.
  The ChuiCore contract copy (`test/contracts/chui-core.md`, v0, binding since 2026-10-19,
  coordinator commit ff0100a) is vendored for `scripts/contract_usage.jl`.
- Factory 0.2.4, package profile (`.factory-version`, source coordinator commit ff0100a).
  Changelog entries go in `changelog.d/` fragments; lane cap is 6 (`max_open`, checked by
  `scripts/check_claims.jl`). `docs/agent/ECOSYSTEM.md` and `BRIEF.md` match coordinator commit
  ff0100a (the coordinator history was rewritten; the earlier provenance hash no longer exists).
- `test/runtests.jl` matches ChuiCore.jl: `:contract` items never run there (not even under
  `-- all`); they run in `test/contracts/` via `julia scripts/ci.jl contracts`.
- L0 (★) was answered on 2026-10-19 (coordinator `HANDOFF.md`: all recommendations accepted),
  so these defaults stand:
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

- (Resolved at L0, 2026-10-19) versioning `0.0.x` (ADR-0004), Julia floor 1.10 (ADR-0006),
  Runic (ADR-0007), MIT license, benchmarks and coverage (ADR-0011).
- ChuiCore's first release: needed before any `[deps]` entry or contract test.
- (Resolved) The factory 0.2.1 bugs reported to the lead were rechecked on factory 0.2.4
  (2026-10-20): `scripts/ratchet.jl` → `OK` (`bash_guard.sh` is 86 lines, split into helpers);
  `ci.jl jet` runs in a scratch copy and left `git status` clean; `.gitignore` has
  `/test/jet/Manifest*.toml`; `.agents/factory.toml` keeps the `[check_docs] exclude` for the
  verbatim copies (the earlier user-authorized T3 edit). `ci.jl docs` was not rerun here.

## Next action

- Phase 1 (Research and ADRs) per `docs/agent/BRIEF.md`, started by the lead at L1: write ADRs
  on the type-stable encoding, the effect runtime (fibers or `Task`s, cancellation) and the
  stream design (push or pull, backpressure), then report to the lead before implementing.
