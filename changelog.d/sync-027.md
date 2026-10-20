- Synced the ecosystem factory template 0.2.6 -> 0.2.7 (see `.factory-version`): `ci.jl --timeout
  SECONDS` (or `CI_TIMEOUT`) kills the whole process group and exits 124; the Benchmark workflow runs
  `scripts/ci.jl bench`; evidence files record the termination signal; merge bases fall back from
  `origin/<b>` to a local `<b>`; check_docs skips Documenter `@ref` links.
- `test/runtests.jl` decides "stable" by Julia version: with `CI_STABLE` unset, `:doctest`/`:snapshot`
  items run iff `VERSION >= STABLE_MIN` (`v"1.13"`, ADR-0008 §3), so a plain `]test` on the LTS skips
  them. `CI_STABLE` of exactly `"true"`/`"false"` still overrides; any other value is an `ArgumentError`.
