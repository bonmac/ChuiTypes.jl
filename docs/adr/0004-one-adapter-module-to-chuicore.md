# ADR-0004: Every use of ChuiCore goes through one adapter module

- **Status:** Accepted (2026-10-20, user at the ChuiTypes phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint (via the lead)
- **Scope:** ChuiTypes.jl

## Context

- ChuiTypes depends on ChuiCore (root ADR-0002 §1), but only on registered `0.0.x` snapshots
  (root ADR-0004 rule 2). ChuiCore is unreleased, and its phase-1 ADRs have not started. ("Root
  ADR-NNNN" means the coordinator's `adr/`.)
- **What ChuiCore's contract (`test/contracts/chui-core.md` v0) makes stable:**
  - `⨟`/`opcompose` (CC-001, CC-002);
  - the aggregation protocol `init`/`partial`/`combine(agg, a, b)`/`final` (CC-004 to CC-007);
  - no Base collisions (CC-010);
  - law kits that are not hard dependencies (CC-011).
- **What it leaves PROVISIONAL**, which ChuiTypes needs:
  - the typeclass trait encoding and operation names (only `neutral` is decided);
  - the law kits;
  - the transducer names;
  - `papply`;
  - the ADT library choice.
- Brief 20, "Independence": implement the types first, "and put a thin adapter layer where
  ChuiCore's traits will plug in".
- **Export collisions.** Exporting a ChuiTypes `flatmap` that later differs from ChuiCore's would
  collide (CC-002 pattern, root ADR-0009 §6).
- **Extending through a constant.** An `Upstream.f` defined as `using ChuiCore: f`, or as
  `const f = ChuiCore.g`, is extended by methods written as `Upstream.f(…) = …` in other files.
  Checked with mock modules on 1.13.2 and 1.10.12 (`.lanes/evidence/mockupstream-{113,110}`:
  `using-import: methods=1 call=2` and `const-alias: methods=1 call=2` on both).
- **Supposition on 1.10.** Supposition 0.3.5 on 1.10.12 does not record a failing `@check` in a
  `@testset`. The lead reproduced this; the workaround is `@check record=false` plus `@test`
  (root ADR-0007 §2 amendment pending).

## Decision

1. **One adapter module.** The file src/upstream.jl (created in phase 2) defines the internal
   module `ChuiTypes.Upstream`.
   - It is the **only** file that may mention ChuiCore. Every other file uses `Upstream.<name>`.
   - A `:quality` test greps `src/` and `ext/` for `\bChuiCore\b` (covering `using`, `import` and
     qualified forms) outside that file.
   - Blind spots (`getfield`, `eval`) go into `docs/CHECK_COVERAGE.md` with the test.
2. **Before ChuiCore's release, `Upstream` declares local stand-ins:** empty generic functions
   for the typeclass operations ChuiTypes needs, and a minimal, **temporary** transducer fold over
   a chunk.
   - Only `neutral` is a ChuiCore-decided name. The rest (`flatmap`, `ap`, `fold`, `Map`,
     `Filter`, `Take`, `foldxl`, the semigroup operation, …) are **ChuiTypes proposals**, sent to
     ChuiCore as requests.
   - The stand-ins follow the prototype's semantics and carry no extra API, so they stay a
     placeholder, not a copy.
   - **Note 2026-10-20 (user at the ChuiTypes phase-4 ★).** The phase-4 transducer stand-ins
     (`Map`, `Filter`, `Take`, `TakeWhile`, `Scan`, `Partition`, `Composed`, `Reduced`, `asrf`,
     `start`/`next`/`complete`, `opcompose`) re-implement ChuiCore's protocol with its names and
     fields; they are **within this rule for now**. Switching them to ChuiCore 0.0.1 (§3) is
     phase-5 item 1, ahead of the stream cost work.
3. **Switch-over.**
   - When names, signatures and trait encoding match, adopting a ChuiCore snapshot is a
     **one-file change**: each stand-in becomes `using ChuiCore: x` or `const x = ChuiCore.y`.
     ChuiCore then enters `[deps]` with the exact snapshot as compat.
   - **A rename** is still one file, through a `const` alias.
   - **A different argument order, `neutral` signature or trait encoding** (instance
     declarations) is a planned multi-file change on its own branch, with its own review.
4. **No typeclass operation names are exported** before ChuiCore accepts them.
   - Users get Base functions on owned types (`map`, `iterate`, `foldl`, `get`, `show`).
   - The qualified `ChuiTypes.<op>` names are **not public**: downstream packages must not use them
     before the switch-over, and the docs say they may change.
   - After the switch-over, ChuiTypes may re-export **ChuiCore's binding** (`===`, CC-002).
5. **Laws.**
   - Until ChuiCore's kits ship, each instance gets local law tests in `test/laws/`, tagged
     `:laws`, through a helper shaped like the recommended kits (`test_<class>_laws(inst, gen;
     eq)`), using `@check record=false` plus `@test`.
   - `eq` is the type's own `isequal` (ADR-0001 §5). `Reader`/`Writer`/`State`/`Effect` compare
     by running both sides on sample inputs.
   - The helper is deleted when a kit ships.
6. **Contract tests.** Each CC-ID that is relied on gets a `USED.md` line and one `:contract`
   item (root ADR-0010 rule 1). No placeholders.
7. **Requests, not edits.** The lane drafts the requests; the lead files them. The known ones:
   - **(R1)** typeclass operation names and the trait encoding, including a semigroup operation
     distinct from CC-004's three-argument `combine`; superseded in part: the stand-ins must follow
     ChuiCore ADR-0001 (`combine(m, a, b)` on an instance value, fresh `neutral(m)`, `pure(tag, x)`);
   - **(R2)** the law-kit form and its Supposition 1.10 workaround;
   - **(R3)** the transducer names and the guarantee of a type-stable fold over a chunk;
   - **(R4)** a first `0.0.x` snapshot;
   - **(R5)** memoised thunks, if `LazyList` should reuse ChuiCore's laziness.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Wait for ChuiCore's release | Contradicts brief 20 "Independence", and serialises the ecosystem. |
| `Pkg.develop` or a git URL to ChuiCore now | Released versions only (ECOSYSTEM §2; root ADR-0004). |
| Export our own typeclass names now | A breaking change later, and a different binding (CC-002, root ADR-0009 §6). |
| `ChuiCore.` calls scattered through `src/` | Every upstream rename would touch every file. |
| A package extension keyed on ChuiCore | ChuiCore is a hard edge (root ADR-0002 §1). |
| Vendor ChuiCore's code | Adapters, not copies (ECOSYSTEM §1.3). |

## Consequences

- Phase 2 starts before ChuiCore's release. The cost is a switch-over per snapshot, and law
  helpers that are deleted later.
- If ChuiCore's encoding differs from the stand-ins, ChuiTypes pays a multi-file migration, as
  §3 says plainly.
- Users qualify operations until the switch-over, and the names may change. This is acceptable
  only because they are not public.

## Verification

- `test/contracts/chui-core.md` v0 (coordinator ff0100a) and `contracts/chui-types.md`.
- The extension through `using`/`const` is `mockupstream-*`, from the script
  `docs/research/scripts/encoding/mock_upstream.jl`.
- Name evidence: `.lanes/evidence/names-*`, `ctor-names-*`, `runtime-names-*`.
- UNVERIFIED here: the Supposition 1.10 finding (the lead reproduced it, not this lane).

## Revisit when

- ChuiCore registers a snapshot, picks names that differ from the stand-ins, or ships its kits.
- Root ADR-0007 §2 is amended for Supposition on 1.10.
