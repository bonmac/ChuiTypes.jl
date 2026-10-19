# ChuiTypes.jl

Data types, effects and streams for the Chui ecosystem: `Option`/`Either`/`Validation`,
`Reader`/`Writer`/`State`/`IO`, a ZIO-style effect runtime, lazy cancellable futures and
reactive streams. It builds on ChuiCore.jl, and ChuiFrames.jl builds on it.

**Status:** pre-release scaffold. Nothing is implemented or exported yet; the package is not
registered. See `HANDOFF.md` for the current state and `docs/agent/BRIEF.md` for the plan.

## Development

```sh
julia --project=. -e 'using Pkg; Pkg.test()'   # unit tests
julia scripts/ci.jl --list                     # every CI job, runnable locally
```

Licensed under MIT (see `LICENSE`).
