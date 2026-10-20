# ChuiTypes.jl

Data types, effects and streams for the Chui ecosystem.

**Status:** pre-release, not registered. Phases 1–3 are implemented: the core data types, Reader,
Writer and State, and the effect runtime with its Task adapters. Streams and futures are phase 4.
Every name below is provisional until v0.1.0. The full guide comes in phase 6; until then this
page lists the docstrings.

```@docs
ChuiTypes
```

## API

```@autodocs
Modules = [ChuiTypes, ChuiTypes.Upstream]
Filter = t -> t !== ChuiTypes
```
