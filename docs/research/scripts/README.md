# Phase-1 experiment scripts

Copies of the scripts behind the evidence entries in `docs/research/*.md` and ADRs 0001–0006,
kept so that the runs can be repeated after the session scratchpads are gone.

- **Provenance.** `sumtypes/`, `effects/` and `streams/` come from the three researcher sub-agents.
  `encoding/` and `names/` come from the lane. `critic/` comes from the two critic reviews;
  `sv_flush.jl` is the lane's copy of `sv.jl` with `flush(stdout)` added.
- **Formatting.** All files were Runic-formatted **after** the runs (formatting only), so the
  repo-wide `ci.jl format` check passes. The evidence files in `.lanes/evidence/` (gitignored) were
  produced by the unformatted copies.
- **How to run.** Run each script on both Julia versions, e.g.
  `julia --startup-file=no scripts/evidence.jl <kind> -- julia +release --startup-file=no <script>`
  and the same with `+lts`. Thread counts and environments are noted in the research entry that
  cites the script.
- **Environments.** Scripts that need packages (BenchmarkTools, SumTypes, Moshi, MLStyle, Rocket,
  Transducers, ScopedValues) were run in throwaway scratch environments, which are not kept here.
  `effects/run.sh` still names the original scratch path.
- **Left out.** Julia's `base/cancellation.jl` from the 1.14 branch (EFF-02); read it upstream.
