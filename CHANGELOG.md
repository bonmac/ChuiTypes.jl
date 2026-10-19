# Changelog

All notable changes to this package are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).
Every PR adds a changelog entry (checked by `scripts/dod.jl`): a lane adds a new
`changelog.d/<lane>.md` fragment, which `julia scripts/changelog.jl fold` moves under
`## Unreleased` at release; a change outside lanes may edit `## Unreleased` directly. Breaking
changes carry migration notes.

## Unreleased

- Scaffold: empty `ChuiTypes` module (version 0.0.1, Julia 1.10+), TestItemRunner tests with
  Aqua and ExplicitImports quality items, a Documenter skeleton, the ChuiCore contract copy
  (`test/contracts/`), and the vendored ecosystem factory template 0.2.1 (see `.factory-version`).
