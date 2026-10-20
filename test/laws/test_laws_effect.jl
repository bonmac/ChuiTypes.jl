# Law tests for Effect (spec §13): Functor, Applicative, Monad through the local kits. Effects have
# no structural equality; `eq` runs both sides and compares their `Exit`s (ADR-0001 §8's rule).

@testitem "laws: Effect" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const T = ChuiTypes.EffectTag()
    runeq(a, b) = isequal(runexit(a), runexit(b))
    # successes, failures, and suspended (`sync`) successes, so laws see every node kind
    effs = map(x -> x % 3 == 0 ? fail(x) : x % 3 == 1 ? succeed(x) : sync(() -> x), L.ints)
    effk = Data.SampledFrom(
        Function[
            x -> succeed(x + 1), x -> iseven(x) ? succeed(x ÷ 2) : fail(x), x -> sync(() -> 2x),
            x -> map(y -> y - 1, succeed(x)),
        ]
    )
    ff = Data.SampledFrom(Any[succeed(x -> x + 1), succeed(x -> 2x), fail(-1), sync(() -> (x -> -x))])
    L.test_functor_laws(T, effs, L.intfns; eq = runeq)
    L.test_applicative_laws(T, L.ints, effs, L.intfns, ff; eq = runeq)
    L.test_monad_laws(T, L.ints, effs, effk, ff; eq = runeq)
end
