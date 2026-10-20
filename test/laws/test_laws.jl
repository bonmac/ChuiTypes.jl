# Law tests for every instance in ADR-0001 §10, through the local kits (test/laws/kits.jl).

@testitem "laws: Option" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    const T = ChuiTypes.OptionTag()
    ff = Data.SampledFrom(Any[some(x -> x + 1), some(x -> 2x), some(x -> -x), none(Function)])
    L.test_functor_laws(T, L.options, L.intfns)
    L.test_applicative_laws(T, L.ints, L.options, L.intfns, ff)
    L.test_monad_laws(T, L.ints, L.options, L.optfns, ff)
    L.test_alternative_laws(T, Int, L.options)
    L.test_foldable_laws(L.options)
    L.test_traversable_laws(L.options, L.optfns, L.eitherfns)
    struct Plus end
    U.combine(::Plus, a::Int, b::Int) = a + b
    L.test_monoid_laws(ChuiTypes.OptionMonoid(Plus(), Int), L.options)
end

@testitem "laws: Either" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const T = ChuiTypes.EitherTag{String}()
    ff = Data.SampledFrom(Any[right(String, x -> x + 1), right(String, x -> 2x), left("f", Function), left("g", Function)])
    strfns = Data.SampledFrom(Function[s -> s * "x", reverse, s -> s^2, identity])
    L.test_functor_laws(T, L.eithers, L.intfns)
    L.test_applicative_laws(T, L.ints, L.eithers, L.intfns, ff)
    L.test_monad_laws(T, L.ints, L.eithers, L.eitherfns, ff)
    L.test_bifunctor_laws(L.eithers, strfns, L.intfns)
    L.test_foldable_laws(L.eithers)
    L.test_traversable_laws(L.eithers, L.optfns, L.eitherfns)
end

@testitem "laws: Validation" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    const T = ChuiTypes.ValidationTag{String}()
    struct Plus end
    U.combine(::Plus, a::Int, b::Int) = a + b
    S = ChuiTypes.ValidationSemigroup(Plus())
    vals = map(
        x -> x % 8 == 0 ? U.combine(S, invalid("a$x", Int), invalid("b$x", Int)) :
            x % 4 == 0 ? invalid(string(x), Int) : valid(x, String), L.ints
    )
    ff = Data.SampledFrom(Any[valid(x -> x + 1, String), valid(x -> 2x, String), invalid("f", Function), invalid("g", Function)])
    strfns = Data.SampledFrom(Function[s -> s * "x", reverse, s -> s^2, identity])
    L.test_functor_laws(T, vals, L.intfns)
    L.test_applicative_laws(T, L.ints, vals, L.intfns, ff)
    L.test_bifunctor_laws(vals, strfns, L.intfns)
    L.test_foldable_laws(vals)
    L.test_traversable_laws(vals, L.optfns, L.eitherfns)
    L.test_semigroup_laws(S, vals)
end

@testitem "laws: These" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    using ChuiTypes: this, that, both
    const L = LawKits
    const U = ChuiTypes.Upstream
    struct Log
        xs::Vector{String}
    end
    Base.isequal(a::Log, b::Log) = isequal(a.xs, b.xs)
    Base.hash(a::Log, h::UInt) = hash(a.xs, h)
    struct LogM end
    U.combine(::LogM, a::Log, b::Log) = Log(vcat(a.xs, b.xs))
    U.default_monoid(::Type{Log}) = LogM()
    const T = ChuiTypes.TheseTag{Log}()
    thesev = map(
        x -> x % 3 == 0 ? this(Log([string(x)]), Int) : x % 3 == 1 ? that(Log, x) : both(Log(["b$x"]), x), L.ints
    )
    ff = Data.SampledFrom(Any[that(Log, x -> x + 1), both(Log(["f"]), x -> 2x), this(Log(["t"]), Function)])
    kfns = Data.SampledFrom(Function[x -> both(Log(["k"]), x + 1), x -> that(Log, 2x), x -> this(Log(["n"]), Int)])
    logfns = Data.SampledFrom(Function[l -> Log(vcat(l.xs, ["x"])), l -> Log(reverse(l.xs)), identity])
    L.test_functor_laws(T, thesev, L.intfns)
    L.test_bifunctor_laws(thesev, logfns, L.intfns)
    L.test_foldable_laws(thesev)
    L.test_traversable_laws(thesev, L.optfns, L.eitherfns)
    L.test_applicative_laws(T, L.ints, thesev, L.intfns, ff)
    L.test_monad_laws(T, L.ints, thesev, kfns, ff)
end

@testitem "laws: NonEmpty" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const T = ChuiTypes.NonEmptyTag()
    nes = map(v -> nonempty(v...), Data.Vectors(L.ints; min_size = 1, max_size = 4))
    ff = Data.SampledFrom(Any[nonempty(x -> x + 1), nonempty(x -> 2x, x -> -x), nonempty(identity, x -> x ÷ 3, x -> 0)])
    kfns = Data.SampledFrom(Function[x -> nonempty(x), x -> nonempty(x, -x), x -> nonempty(x, x + 1, x + 2)])
    L.test_functor_laws(T, nes, L.intfns)
    L.test_applicative_laws(T, L.ints, nes, L.intfns, ff)
    L.test_monad_laws(T, L.ints, nes, kfns, ff)
    L.test_foldable_laws(nes)
    L.test_traversable_laws(nes, L.optfns, L.eitherfns)
    L.test_semigroup_laws(ChuiTypes.NonEmptySemigroup(), nes)
end

@testitem "laws: LazyList" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const T = ChuiTypes.LazyListTag()
    lls = map(v -> lazylist(v), Data.Vectors(L.ints; max_size = 4))
    ff = Data.SampledFrom(Any[lazylist(Function[x -> x + 1]), lazylist(Function[x -> 2x, x -> -x]), lazynil(Function)])
    kfns = Data.SampledFrom(Function[x -> lazylist([x]), x -> lazylist([x, -x]), x -> lazynil(Int), x -> lazylist(x:(x + 2))])
    L.test_functor_laws(T, lls, L.intfns)
    L.test_applicative_laws(T, L.ints, lls, L.intfns, ff)
    L.test_monad_laws(T, L.ints, lls, kfns, ff)
    L.test_alternative_laws(T, Int, lls)
    L.test_foldable_laws(lls)
    L.test_monoid_laws(ChuiTypes.LazyListMonoid(Int), lls)
end
