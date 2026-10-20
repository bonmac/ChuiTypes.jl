# Phase 2 plan: core data types, plus laws

- **Lane:** `phase2-datatypes`, branch `feat/phase2-datatypes`, from `main` at `455c085`.
- **Tier:** T2 (public API, `Project.toml`). Spec: the phase-1 design
  `docs/superpowers/specs/2026-10-20-phase1-research-design.md` plus the accepted ADRs 0001, 0004
  and 0005; the phase-2 decisions that the ADRs leave open are recorded in
  `docs/superpowers/specs/2026-10-20-phase2-datatypes-design.md`.
- **Out of scope:** Reader/Writer/State, Effect and the IO constructor, streams, futures, the
  transducer stand-in (phases 3 and 4).

## Tasks (TDD: each test file is written and seen failing before its source file)

1. `src/upstream.jl`: the `Upstream` module (ADR-0004 §1, §2), with empty generic functions that
   mirror ChuiCore ADR-0001: `fmap`, `pure(tag, x)`, `ap`, `chain`, `alt`, `zeroalt(tag, T)`,
   `bimap`, `traverse(tag, f, x)`, `combine(m, a, b)`, `neutral(m)`, `default_monoid(T)`,
   `constructorclass(T)`. Test: `test/test_upstream.jl` (only file naming ChuiCore; grep test).
2. `src/common.jl`: the ADR-0001 §4 parameter rule (`promote_op`, never asserted) and the tags.
   Test: the three `:quality` cases (`Union{}`, a `Union` of Options, `Any` give `Any`).
3. One source file and one test file per type: `option`, `either`, `validation`, `these`,
   `nonempty`, `lazylist`. Each: constructors (ADR-0001 §3), accessors, `==`/`isequal`/`hash`/`show`
   over the active slots (§5), iteration (Foldable), the instance methods of §10, `@inferred`
   and zero-allocation tests (§11).
4. `test/laws/kits.jl`: a `@testmodule` with `test_<class>_laws(inst, gens...; eq)` helpers for
   Semigroup, Monoid, Functor, Applicative, Monad, Alternative, Foldable, Traversable and
   Bifunctor (ADR-0004 §5). Every property is `@check record=false db=false` plus `@test` on the
   report (ecosystem ADR-0007 §2 amendment). Each law is its own inner `@testset`.
5. `test/laws/test_laws_<type>.jl`: every instance of ADR-0001 §10 through the helpers.
6. `test/laws/test_planted.jl`: one planted violation per law, run in a capturing test set,
   asserting that the inner test set named after the law records a failure. Runs on 1.10.
7. `test/test_quality.jl`: `isconcretetype`, `@inferred` chains, the ChuiCore grep test.
   `test/test_ct003.jl`: CT-003 over the exports.
8. `benchmark/benchmarks.jl` + `benchmark/Project.toml`: `SUITE` for the four zero-allocation
   chains.
9. Docs: `docs/CHECK_COVERAGE.md` is generated, so the grep test's blind spots go in the spec
   and HANDOFF; `changelog.d/phase2-datatypes.md`; `HANDOFF.md`.

## Gates

`ci.jl test` (1.13.2), `julia +lts` `Pkg.test()`, `ci.jl test -- all`, `quality`, `jet`, `format`,
`guards`, `contracts`, `dod.jl --base main`, `scripts/lane audit phase2-datatypes`, then the
read-only reviewer on the full diff.
