- Synced the ecosystem factory template 0.2.8 -> 0.3.0 (see `.factory-version`; coordinator
  ADR-0015): test-first lanes with separate contexts. A new `test-writer` role writes a lane's red
  tests from the spec and the public API without seeing `src/`; a fresh `implementer` (now limited
  to `src/**`, `ext/**`, `changelog.d/**`) writes the code. The law, property and differential
  testers may author the test phases too.
- `scripts/tdd.jl` (`red`, `green`, `api`, `brief`, `audit`, `gaps`, `mutate`) and its helpers
  `_tdd_classify.jl`, `_tdd_history.jl`, `_tdd_evidence.jl`, `_tdd_backfill.jl` (T3).
- New hooks `tdd_boundary.sh` (with `_tdd_allow.sh`, `_tdd_commit_guard.sh`) and
  `tdd_commit_post.sh`: the test-side roles' read/write/Bash boundary, the lead-only TDD dispatch,
  and every role commit's author, phase and paths, recorded in the ledger.
- `dod.jl` gains the `tdd` requirement (history rules H1-H9), now in the T1-T3 tiers of
  `risk.toml`. A code lane without the test-writer and implementer needs a lead
  `TDD-Mode: skip — <reason>` commit.
- `test/runtests.jl` selects single items with `item=<name>` and records the matched names in
  `TDD_MATCHED`. Tag selection is unchanged, except that on non-stable Julia `:doctest` and
  `:snapshot` items are no longer selectable by tag (`-- doctest`, `-- all`).
- `/change-review`, the `lane-lifecycle` skill, the reviewer and tester bodies, `checks.toml` and
  `docs/CHECK_COVERAGE.md` describe test-first lanes and the new blind spots.
