- Synced the ecosystem factory template to 0.2.4 (see `.factory-version`): changelog fragments in
  `changelog.d/`, `scripts/check_claims.jl`, `scripts/evidence.jl`, lane `--owns`/`audit`, a
  split `bash_guard`, a contract-test environment in `test/contracts/`, and more T3-protected
  gate scripts in `risk.toml`. The lane cap is now 6. The rendered `read-only-roots.txt` is
  gitignored.
- Refreshed the coordinator copies `docs/agent/ECOSYSTEM.md`, `docs/agent/BRIEF.md` and
  `test/contracts/chui-core.md` (contract v0, now binding) from coordinator commit ff0100a.
- `test/runtests.jl` never runs `:contract` items, even under `-- all`: they run in
  `test/contracts/`'s own environment via `julia scripts/ci.jl contracts` (matches ChuiCore.jl).
- `test/jet/Project.toml` gains `[compat]` bounds `TOML = "1"` and `julia = "1.12"`.
