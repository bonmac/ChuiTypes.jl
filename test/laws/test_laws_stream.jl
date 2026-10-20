# Law tests for Stream (phase-4 spec §12): Functor, Applicative, Monad through the local kits.
# Streams have no structural equality; `eq` runs both sides and compares their `Exit`s.

@testitem "laws: Stream" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const T = ChuiTypes.StreamTag()
    runeq(a, b) = isequal(runexit(runcollect(a)), runexit(runcollect(b)))
    small = Data.Vectors(L.ints; max_size = 5)
    # finite streams at several chunk sizes, and failing ones
    strs = map(Data.Pairs(small, Data.Integers(0, 3))) do (xs, k)
        k == 0 ? concat(fromiter(xs), failstream(length(xs))) : fromiter(xs; chunksize = k)
    end
    strk = Data.SampledFrom(
        Function[
            x -> fromiter([x, x + 1]), x -> iseven(x) ? emptystream(Int) : fromiter([x]),
            x -> x % 5 == 0 ? failstream(x) : fromiter([2x]), x -> map(y -> y - 1, fromiter([x])),
        ]
    )
    ff = Data.SampledFrom(Any[fromiter([x -> x + 1, x -> 2x]), emptystream(Function), fromiter([x -> -x]), failstream(-1)])
    L.test_functor_laws(T, strs, L.intfns; eq = runeq)
    L.test_applicative_laws(T, L.ints, strs, L.intfns, ff; eq = runeq)
    L.test_monad_laws(T, L.ints, strs, strk, ff; eq = runeq)
end

@testitem "planted: a Stream ap in the wrong order fails the laws" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    struct Rev
        s::Stream
    end
    struct RevTag end
    U.pure(::RevTag, x) = Rev(fromiter([x]))
    U.fmap(f, a::Rev) = Rev(map(f, a.s))
    U.chain(k, a::Rev) = Rev(concatmap(x -> k(x).s, a.s))
    U.ap(ff::Rev, fx::Rev) = Rev(concatmap(x -> map(f -> f(x), ff.s), fx.s))   # wrong order
    eq(a, b) = isequal(runexit(runcollect(a.s)), runexit(runcollect(b.s)))
    revs = map(xs -> Rev(fromiter(xs)), Data.Vectors(L.ints; max_size = 4))
    kf = Data.SampledFrom(Function[x -> Rev(fromiter([x, x + 1])), x -> Rev(fromiter([2x]))])
    ff = Data.SampledFrom(Any[Rev(fromiter([x -> x + 1, x -> 2x])), Rev(fromiter([x -> -x]))])
    failed, passed = L.planted(() -> L.test_monad_laws(RevTag(), L.ints, revs, kf, ff; eq))
    @test "monad: ap is chain" in failed
    @test "monad: associativity" in passed
end
