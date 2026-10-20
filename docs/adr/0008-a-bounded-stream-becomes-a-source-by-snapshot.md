# ADR-0008: A bounded stream becomes a ChuiFrames Source by a snapshot taken at construction

- **Status:** Proposed (critic: ACCEPT WITH FIXES on the first draft; fixes 10a–10e applied)
- **Date:** 2026-10-20
- **Deciders:** the user at the ChuiTypes phase-4 ★ (via the lead). The adapter's own rules
  belong to ChuiFrames (ecosystem ADR-0002 §1) and go there through request R10.
- **Scope:** ChuiTypes.jl: what its public stream API **guarantees** a Source adapter

## Context

- The brief requires streams to be usable as a ChuiFrames `Source`. ADR-0003 §10 provides
  `withbatches(f, s)` and explicitly does **not** claim that it satisfies `chui-frames.md`'s
  Source rules. Request R10 (ChuiFrames → ChuiTypes) asks for the ChuiTypes half.
- `chui-frames.md` CF-011: a Source is `source_schema(s)::Tables.Schema` (known up front),
  `plan_partitions(s, scan; morsel)` returning a **finite** `Vector` of handles, and
  `read_partition(s, p)` returning a table per handle; `isthreadsafe(s)` defaults to `false`;
  "any Tables.jl input is a Source, and the partition list is **snapshotted when the source is
  built**, so `explain` followed by `collect` plans the same partitions". CF-015: v0 sources are
  bounded; a streaming variant will be a new method.
- ChuiTypes streams (ADR-0003) are cold descriptions run as effects, possibly unbounded,
  possibly concurrent (`merge`, `mergemap`, hot `Subject`s, time operators). Re-running a cold
  stream repeats its **elements** only when every source is deterministic; chunk boundaries and
  interleavings depend on timing (`merge` orders chunks by arrival).
- A Source's partitions must be re-readable and must not change between `explain` and `collect`.

## Decision

ChuiTypes guarantees, and documents, the following. The recommended adapter rule ("snapshot once
at construction, never re-run per plan or partition") is ChuiFrames' to adopt, through R10.

1. **A snapshot effect.** `runchunks(s; maxelements = nothing)` runs `s` once and succeeds with
   its chunks in order. Every chunk is a **fresh vector owned by the run**, never a view of a
   user's array and never touched by ChuiTypes again, so the snapshot is re-readable and safe to
   read from several threads (`isthreadsafe` may be `true`).
2. **A memory bound, not a time bound.** With `maxelements = n`, a stream with more elements
   fails with `Fail(ArgumentError)` after reading `n + 1`. ChuiTypes cannot prove a stream finite;
   a source that never ends nor fills the bound (`interval(1)`, an unclosed `subscribe`) hangs
   the snapshot, so an adapter should pass a bound and wrap the snapshot in `timeoutfail`.
3. **An advisory element type.** `eltype(s)` is a supertype of every element, possibly wider than
   the real one. When it is a concrete `NamedTuple{names, types}` it can be the schema; otherwise
   the adapter derives one from the snapshot or takes one from the user. An empty stream with a
   non-concrete `eltype` needs a user schema.
4. **Chunks are row tables.** A chunk is an `AbstractVector` of the stream's elements; a chunk of
   `NamedTuple`s is a Tables.jl row table. Chunk sizes are not promised (hot sources give small
   partial chunks), so an adapter may coalesce consecutive chunks deterministically, for example
   to `morsel` rows; that keeps the plan stable because the snapshot is fixed.
5. **Public names for this** (qualified use is enough): `runchunks`, `eltype` on `Stream`,
   `withbatches` (for one-pass consumers, such as a streaming Source later or a Sink), the run
   functions, `timeoutfail`. ChuiTypes ships no ChuiFrames extension (ecosystem ADR-0002 §1).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Re-run the cold stream for each partition read | Interleavings and chunk boundaries change between runs (`merge`, hot sources, time operators), and every read repeats the upstream I/O. |
| Partition handle = "the k-th chunk of a fresh run" | Same: not stable, and O(k) per read. |
| An `isfinite(s)` trait on streams | Undecidable for `retry`, `interval`, hot sources; a bound on the snapshot is checkable. |
| Exact element type in `Stream`'s parameter | Advisory parameters are the runtime's rule (ADR-0002 §1); asserting them costs a check per element. |
| `withbatches` alone as the Source | It is valid only inside its callback: a Source must outlive one call. |

## Consequences

- Memory: a stream-backed source holds its whole snapshot. That is CF-015's v0 promise; a
  streaming Source (a new ChuiFrames method) can later use `withbatches` instead.
- **R10 is not closed by this ADR.** R10 also asks for export tiers and CT IDs for these names,
  and the `chui-types.md` entry "Stream as a ChuiFrames `Source`" needs an amendment (T3, the
  user). Both are draft requests in the phase-4 report. R10 stays open while ChuiFrames' Task shim
  exists (its own rule).
- ChuiTypes tests the guarantees with a mock source (`test/test_stream_source.jl`): schema from
  `eltype`, partitions from `runchunks`, two plans equal, a bound violation fails.

## Verification

- `test/test_stream_source.jl` on 1.10.12 and 1.13.2 (the phase-4 report pastes the run).
- Contract text: `<root>/contracts/chui-frames.md` CF-011, CF-015 (read 2026-10-20).
- UNVERIFIED: ChuiFrames' real `TablesSource` conversion of a `Vector{NamedTuple}` chunk; no
  ChuiFrames code is run by this lane.

## Revisit when

- ChuiFrames adds a streaming Source method (CF-015), or decides its Source shape differently.
- A chunk type other than `AbstractVector` (for example a columnar chunk) is introduced.
