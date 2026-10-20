# Law tests for Reader, Writer and State (ADR-0007 §4, §5), through the local kits
# (test/laws/kits.jl). The values have no `==`: `eq` runs both sides on sample inputs
# (environments, initial states, monoids) and compares the results.
#
# Some continuations change the value's type (Int to Float64 or Bool), so a converting `chain`
# breaks associativity; the continuations that feed a value into the environment, the state
# or the log go through `_i` so that they accept those values too.

@testsnippet RWSLawHelpers begin
    _i(x) = x isa Bool ? Int(x) : floor(Int, x)
end

@testitem "laws: Reader" tags = [:laws] setup = [LawKits, RWSLawHelpers] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    const T = ChuiTypes.ReaderTag{Int}()
    envs = (0, 1, -5, 9)
    eq(a, b) = all(r -> isequal(runreader(a, r), runreader(b, r)), envs)
    readers = map(
        x -> x % 4 == 0 ? U.pure(T, x) : x % 4 == 1 ? asks(r -> r + x, Int) :
            x % 4 == 2 ? withreader(r -> 2r, asks(r -> r - x, Int)) :
            andthen(r -> U.pure(T, r * x), ask(Int)), L.ints
    )
    kfns = Data.SampledFrom(
        Function[
            x -> U.pure(T, x + 1), x -> asks(r -> r * x, Int), x -> withreader(r -> r + _i(x), ask(Int)),
            x -> iseven(x) ? asks(r -> r + 0.5, Int) : U.pure(T, x isa Int),
        ]
    )
    ff = Data.SampledFrom(
        Any[U.pure(T, x -> x + 1), asks(r -> (x -> x * r), Int), withreader(r -> -r, asks(r -> (x -> x - r), Int))]
    )
    L.test_functor_laws(T, readers, L.intfns; eq)
    L.test_applicative_laws(T, L.ints, readers, L.intfns, ff; eq)
    L.test_monad_laws(T, L.ints, readers, kfns, ff; eq)
end

@testitem "laws: State" tags = [:laws] setup = [LawKits, RWSLawHelpers] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    const T = ChuiTypes.StateTag{Int}()
    states0 = (0, 1, -3, 7)
    eq(a, b) = all(s -> isequal(runstate(a, s), runstate(b, s)), states0)
    then(m, x) = andthen(_ -> U.pure(T, x), m)
    states = map(
        x -> x % 4 == 0 ? U.pure(T, x) : x % 4 == 1 ? map(s -> s - x, getstate(Int)) :
            x % 4 == 2 ? andthen(s -> then(putstate(2s + x), s), getstate(Int)) :
            then(modifystate(s -> s - x, Int), x), L.ints
    )
    kfns = Data.SampledFrom(
        Function[
            x -> then(putstate(Int, _i(x)), x + 1), x -> map(s -> s + x, getstate(Int)),
            x -> then(modifystate(s -> 3s - _i(x), Int), x), x -> U.pure(T, 2x),
            x -> iseven(x) ? map(s -> s + 0.5, getstate(Int)) : U.pure(T, x isa Int),
        ]
    )
    ff = Data.SampledFrom(
        Any[
            U.pure(T, x -> x + 1), map(s -> (x -> x * s), getstate(Int)),
            then(modifystate(s -> s + 1, Int), x -> 2x), andthen(s -> then(putstate(-s), x -> x - s), getstate(Int)),
        ]
    )
    L.test_functor_laws(T, states, L.intfns; eq)
    L.test_applicative_laws(T, L.ints, states, L.intfns, ff; eq)
    L.test_monad_laws(T, L.ints, states, kfns, ff; eq)
end

@testitem "laws: Writer" tags = [:laws] setup = [LawKits, RWSLawHelpers] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    struct AppendM end                                 # in place into the run's accumulator
    U.combine(::AppendM, a::Vector{Int}, b::Vector{Int}) = append!(a, b)
    U.neutral(::AppendM) = Int[]
    struct CatM end                                    # copying
    U.combine(::CatM, a::Vector{Int}, b::Vector{Int}) = vcat(a, b)
    U.neutral(::CatM) = Int[]
    struct SumM end
    U.combine(::SumM, a::Int, b::Int) = a + b
    U.neutral(::SumM) = 0
    # AppendM mutates its first argument, so it is lawful only on an accumulator the caller
    # owns (as the Writer run's is), not on shared values: only CatM goes through the kit.
    L.test_monoid_laws(CatM(), Data.Vectors(L.ints; max_size = 3))
    L.test_monoid_laws(SumM(), L.ints)

    # Writer{Vector{Int}}, checked under both list monoids
    TV = ChuiTypes.WriterTag{Vector{Int}}()
    eqv(a, b) = all(mon -> isequal(runwriter(a, mon), runwriter(b, mon)), (AppendM(), CatM()))
    thenv(m, x) = andthen(_ -> U.pure(TV, x), m)
    vws = map(
        x -> x % 4 == 0 ? U.pure(TV, x) : x % 4 == 1 ? thenv(tell([x]), x + 1) :
            x % 4 == 2 ? map(p -> p[1] + length(p[2]), listening(thenv(tell([x, -x]), x))) :
            censor(reverse, thenv(andthen(_ -> tell([2x]), tell([x])), x)), L.ints
    )
    kv = Data.SampledFrom(
        Function[
            x -> thenv(tell([_i(x)]), x + 1), x -> U.pure(TV, 2x),
            x -> censor(w -> [sum(w; init = 0)], thenv(tell([_i(x), 1]), x)),
            x -> iseven(x) ? thenv(tell([0]), x + 0.5) : U.pure(TV, x isa Int),
        ]
    )
    ffv = Data.SampledFrom(Any[U.pure(TV, x -> x + 1), thenv(tell([7]), x -> 2x), thenv(tell([1, 2]), x -> -x)])
    L.test_functor_laws(TV, vws, L.intfns; eq = eqv)
    L.test_applicative_laws(TV, L.ints, vws, L.intfns, ffv; eq = eqv)
    L.test_monad_laws(TV, L.ints, vws, kv, ffv; eq = eqv)

    # Writer{Int} with an Int sum
    TI = ChuiTypes.WriterTag{Int}()
    eqi(a, b) = isequal(runwriter(a, SumM()), runwriter(b, SumM()))
    theni(m, x) = andthen(_ -> U.pure(TI, x), m)
    iws = map(x -> x % 3 == 0 ? U.pure(TI, x) : x % 3 == 1 ? theni(tell(x), -x) : censor(w -> 2w, theni(tell(x), x)), L.ints)
    ki = Data.SampledFrom(Function[x -> theni(tell(_i(x)), x + 1), x -> U.pure(TI, x), x -> censor(w -> w + 1, theni(tell(1), 3x))])
    ffi = Data.SampledFrom(Any[U.pure(TI, x -> x + 1), theni(tell(3), x -> 2x)])
    L.test_functor_laws(TI, iws, L.intfns; eq = eqi)
    L.test_applicative_laws(TI, L.ints, iws, L.intfns, ffi; eq = eqi)
    L.test_monad_laws(TI, L.ints, iws, ki, ffi; eq = eqi)
end
