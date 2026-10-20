# Local law kits (ADR-0004 §5), shaped like the upstream kits will be: instance values or
# constructor tags first, then generators, then `eq`. Deleted when the upstream kits ship.
#
# Every property runs as `@check record=false db=false ...` plus an explicit `@test` on the
# report (ecosystem ADR-0007 §2 amendment): a failing `@check` inside a `@testset` is silently
# dropped on Julia 1.10. `db=false` keeps Supposition from writing an example database
# (ADR-0005 §3). Each law is one inner `@testset "<law>"` holding one `@test`.
@testmodule LawKits begin
    using Test, Supposition
    using ChuiTypes
    const U = ChuiTypes.Upstream

    const MAX = 150

    passed(r) = Supposition.results(r).ispass
    _check(p, g1) = @check record = false db = false max_examples = MAX p(g1)
    _check(p, g1, g2) = @check record = false db = false max_examples = MAX p(g1, g2)
    _check(p, g1, g2, g3) = @check record = false db = false max_examples = MAX p(g1, g2, g3)
    _check(p, g1, g2, g3, g4) = @check record = false db = false max_examples = MAX p(g1, g2, g3, g4)

    "One law: run property `p` over the generators and `@test` the report."
    function law(name::AbstractString, p, gens...)
        @testset "$name" begin
            r = _check(p, gens...)
            @test passed(r)
        end
        return nothing
    end

    # Curried composition, for the Applicative composition law.
    const compose = f -> (g -> (x -> f(g(x))))

    # ---- Semigroup / Monoid (instance values) ----------------------------------------------

    function test_semigroup_laws(m, gen; eq = isequal)
        law("semigroup: associativity", (a, b, c) -> eq(U.combine(m, U.combine(m, a, b), c), U.combine(m, a, U.combine(m, b, c))), gen, gen, gen)
        return nothing
    end

    function test_monoid_laws(m, gen; eq = isequal)
        test_semigroup_laws(m, gen; eq)
        law("monoid: left identity", a -> eq(U.combine(m, U.neutral(m), a), a), gen)
        law("monoid: right identity", a -> eq(U.combine(m, a, U.neutral(m)), a), gen)
        # `neutral(m)` is a fresh value: combining into one never changes the next one
        law(
            "monoid: fresh neutral", a -> begin
                U.combine(m, U.neutral(m), a)
                eq(U.combine(m, U.neutral(m), a), a) && eq(U.combine(m, a, U.neutral(m)), a)
            end, gen
        )
        return nothing
    end

    # ---- Functor ------------------------------------------------------------------------------

    function test_functor_laws(tag, gen_fa, gen_f; eq = isequal)
        law("functor: identity", fa -> eq(U.fmap(identity, fa), fa), gen_fa)
        law("functor: composition", (fa, f, g) -> eq(U.fmap(x -> f(g(x)), fa), U.fmap(f, U.fmap(g, fa))), gen_fa, gen_f, gen_f)
        return nothing
    end

    # ---- Applicative --------------------------------------------------------------------------
    # gen_x: plain values; gen_fa: wrapped values; gen_f: plain functions; gen_ff: wrapped functions.

    function test_applicative_laws(tag, gen_x, gen_fa, gen_f, gen_ff; eq = isequal)
        law("applicative: identity", v -> eq(U.ap(U.pure(tag, identity), v), v), gen_fa)
        law("applicative: homomorphism", (f, x) -> eq(U.ap(U.pure(tag, f), U.pure(tag, x)), U.pure(tag, f(x))), gen_f, gen_x)
        law("applicative: interchange", (u, y) -> eq(U.ap(u, U.pure(tag, y)), U.ap(U.pure(tag, g -> g(y)), u)), gen_ff, gen_x)
        law(
            "applicative: composition", (u, v, w) -> eq(U.ap(U.ap(U.ap(U.pure(tag, compose), u), v), w), U.ap(u, U.ap(v, w))),
            gen_ff, gen_ff, gen_fa
        )
        return nothing
    end

    # ---- Monad --------------------------------------------------------------------------------
    # gen_k: functions from a plain value to a wrapped value; gen_ff: wrapped functions.

    function test_monad_laws(tag, gen_x, gen_m, gen_k, gen_ff; eq = isequal)
        law("monad: left identity", (x, k) -> eq(U.chain(k, U.pure(tag, x)), k(x)), gen_x, gen_k)
        law("monad: right identity", m -> eq(U.chain(x -> U.pure(tag, x), m), m), gen_m)
        law(
            "monad: associativity", (m, k1, k2) -> eq(U.chain(k2, U.chain(k1, m)), U.chain(x -> U.chain(k2, k1(x)), m)),
            gen_m, gen_k, gen_k
        )
        law("monad: ap is chain", (mf, m) -> eq(U.ap(mf, m), U.chain(f -> U.fmap(f, m), mf)), gen_ff, gen_m)
        return nothing
    end

    # ---- Alternative --------------------------------------------------------------------------

    function test_alternative_laws(tag, ::Type{T}, gen_fa; eq = isequal) where {T}
        law("alternative: left identity", a -> eq(U.alt(U.zeroalt(tag, T), a), a), gen_fa)
        law("alternative: right identity", a -> eq(U.alt(a, U.zeroalt(tag, T)), a), gen_fa)
        law("alternative: associativity", (a, b, c) -> eq(U.alt(U.alt(a, b), c), U.alt(a, U.alt(b, c))), gen_fa, gen_fa, gen_fa)
        return nothing
    end

    # ---- Bifunctor ----------------------------------------------------------------------------

    function test_bifunctor_laws(gen_p, gen_f, gen_g; eq = isequal)
        law("bifunctor: identity", p -> eq(U.bimap(identity, identity, p), p), gen_p)
        law(
            "bifunctor: composition", (p, f1, f2, g) -> eq(U.bimap(x -> f1(f2(x)), y -> g(g(y)), p), U.bimap(f1, g, U.bimap(f2, g, p))),
            gen_p, gen_f, gen_f, gen_g
        )
        return nothing
    end

    # ---- Foldable (Base iteration) --------------------------------------------------------------
    # Foldable is Base iteration (upstream ADR-0001 §3); the laws say every fold agrees with
    # folding the collected elements. `gen_t` elements must hold Ints.

    const _op = (a, x) -> 2a - x                     # not commutative, not associative
    function test_foldable_laws(gen_t; eq = isequal)
        law("foldable: foldl", t -> eq(foldl(_op, t; init = 1), foldl(_op, collect(t); init = 1)), gen_t)
        law("foldable: foldr", t -> eq(foldr((x, a) -> _op(a, x), t; init = 1), foldr((x, a) -> _op(a, x), collect(t); init = 1)), gen_t)
        law("foldable: length", t -> length(t) == count(_ -> true, collect(t)), gen_t)
        law("foldable: mapreduce", t -> eq(mapreduce(x -> 3x, _op, t; init = 1), foldl(_op, map(x -> 3x, collect(t)); init = 1)), gen_t)
        return nothing
    end

    # ---- Traversable --------------------------------------------------------------------------
    # The identity and composition laws need two applicatives the kit owns.

    "Identity applicative."
    struct Identity{T}
        x::T
    end
    struct IdTag end
    U.fmap(f, i::Identity) = Identity(f(i.x))
    U.pure(::IdTag, x) = Identity(x)
    U.ap(f::Identity, x::Identity) = Identity(f.x(x.x))
    Base.isequal(a::Identity, b::Identity) = isequal(a.x, b.x)

    "Composition `F{G{a}}` of the applicatives named by tags `tf` and `tg`."
    struct Compose{X}
        x::X
    end
    struct ComposeTag{TF, TG}
        tf::TF
        tg::TG
    end
    U.fmap(h, c::Compose) = Compose(U.fmap(ga -> U.fmap(h, ga), c.x))
    U.pure(ct::ComposeTag, x) = Compose(U.pure(ct.tf, U.pure(ct.tg, x)))
    U.ap(cf::Compose, cx::Compose) = Compose(U.ap(U.fmap(gf -> (gx -> U.ap(gf, gx)), cf.x), cx.x))
    Base.isequal(a::Compose, b::Compose) = isequal(a.x, b.x)

    # The natural transformation Option → Either{String} (an applicative morphism).
    o2e(o::Option{T}) where {T} = issome(o) ? right(String, get(o, nothing)::T) : left("none", T)

    # gen_f: functions value → Option; gen_g: functions value → Either{String}.
    function test_traversable_laws(gen_t, gen_f, gen_g; eq = isequal)
        TO, TE = ChuiTypes.OptionTag(), ChuiTypes.EitherTag{String}()
        law("traversable: identity", t -> eq(U.traverse(IdTag(), Identity, t), Identity(t)), gen_t)
        law("traversable: naturality", (t, f) -> eq(o2e(U.traverse(TO, f, t)), U.traverse(TE, x -> o2e(f(x)), t)), gen_t, gen_f)
        law(
            "traversable: composition", (t, f, g) -> begin
                lhs = U.traverse(ComposeTag(TO, TE), x -> Compose(U.fmap(g, f(x))), t)
                rhs = Compose(U.fmap(t2 -> U.traverse(TE, g, t2), U.traverse(TO, f, t)))
                eq(lhs, rhs)
            end, gen_t, gen_f, gen_g
        )
        return nothing
    end

    # ---- Planted violations -----------------------------------------------------------------
    # A test set that keeps its results instead of reporting them, so a test can assert that a
    # kit FAILED on a deliberately unlawful instance (upstream ADR-0007 §5).

    mutable struct Capture <: Test.AbstractTestSet
        description::String
        results::Vector{Any}
    end
    Capture(desc::AbstractString; kw...) = Capture(String(desc), Any[])
    Test.record(c::Capture, r) = (push!(c.results, r); r)
    function Test.finish(c::Capture)
        if Test.get_testset_depth() > 0
            p = Test.get_testset()
            p isa Capture && Test.record(p, c)
        end
        return c
    end

    _failed(c::Capture) = any(r -> r isa Union{Test.Fail, Test.Error} || (r isa Capture && _failed(r)), c.results)
    _laws(c::Capture) = [r for r in c.results if r isa Capture]

    """
        planted(run) -> (failed laws, passed laws)

    Runs the kit call `run()` inside a capturing test set and returns the names of the law test
    sets that recorded a failure and of those that passed.
    """
    function planted(run)
        c = Test.@testset Capture "planted" begin
            redirect_stdout(run, devnull)
        end
        ls = _laws(c)
        return Set(l.description for l in ls if _failed(l)), Set(l.description for l in ls if !_failed(l))
    end

    # ---- Shared generators ----------------------------------------------------------------------

    const ints = map(Int, Data.Integers{Int8}())
    const intfns = Data.SampledFrom(Function[x -> x + 1, x -> 2x, x -> -x, x -> x ÷ 3, identity, x -> x * x - 1])

    const options = map(x -> x % 4 == 0 ? none(Int) : some(x), ints)
    const optfns = Data.SampledFrom(Function[x -> some(x + 1), x -> iseven(x) ? some(x ÷ 2) : none(Int), x -> none(Int), x -> some(-x)])
    const eithers = map(x -> x % 4 == 0 ? left(string(x), Int) : right(String, x), ints)
    const eitherfns = Data.SampledFrom(Function[x -> right(String, x + 1), x -> x > 0 ? right(String, 2x) : left("neg", Int), x -> left(string(x), Int)])
end
