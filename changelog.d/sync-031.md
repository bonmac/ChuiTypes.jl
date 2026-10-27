- Synced the ecosystem factory template 0.3.0 -> 0.3.1 (see `.factory-version`; coordinator
  factory CHANGELOG 0.3.1, ADR-0015). A patch: managed files only, no seeded hand edit.
- `julia scripts/ci.jl format` passes again. The job picks its own files (`CI.format_files`:
  git-listed `.jl` files minus `scripts/test/fixtures/`) and hands Runic `--check --diff <files>`,
  so the deliberately broken tdd fixture no longer aborts it; the template scripts are Runic-clean.
- One TDD ledger: `tdd-commit` records and `tdd.jl audit`'s default `--ledger` both use the
  ledger of the main checkout of the repo that owns the lane (`owning_ledger`), so a nested
  package's audit no longer reads the coordinator's ledger.
- The TDD roles (test-writer, law/property/differential testers, implementer) are dispatched
  unnamed and report by their final reply (`lane-lifecycle` skill and the role bodies).
- `tdd.jl red` accepts a deletion-only `TDD: test-fix` (recorded `REMOVED <name>` lines), and
  E1 accepts that evidence.
- New factory tests: `test_ci_format.jl`, `test_tdd_ledger.jl`, `test_tdd_testfix_delete.jl`,
  `test_tdd_requested.jl`, `test_hooks_tdd_topo.jl`, `test_docs_031.jl`.
