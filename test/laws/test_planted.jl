# One planted violation per law (ecosystem ADR-0007 §2 amendment; upstream ADR-0007 §5): each
# kit runs on a deliberately unlawful instance inside a capturing test set, and the test asserts
# that the inner test set named after the broken law recorded a failure. Tagged :laws, so it
# runs on the LTS job, where a plain failing `@check` would be dropped.

@testitem "planted: semigroup and monoid" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    struct Minus end                                   # not associative
    U.combine(::Minus, a::Int, b::Int) = a - b
    struct OffNeutral end                              # identity is 1 for +
    U.combine(::OffNeutral, a::Int, b::Int) = a + b
    U.neutral(::OffNeutral) = 1
    struct SharedVec end                               # shared, mutated identity
    const SHARED = Int[]
    U.combine(::SharedVec, a::Vector{Int}, b::Vector{Int}) = append!(a, b)
    U.neutral(::SharedVec) = SHARED
    vecs = Data.Vectors(L.ints; min_size = 1, max_size = 3)

    @test "semigroup: associativity" in first(L.planted(() -> L.test_semigroup_laws(Minus(), L.ints)))
    failed, passed = L.planted(() -> L.test_monoid_laws(OffNeutral(), L.ints))
    @test "monoid: left identity" in failed && "monoid: right identity" in failed
    @test "semigroup: associativity" in passed
    @test "monoid: fresh neutral" in first(L.planted(() -> L.test_monoid_laws(SharedVec(), vecs)))
end

@testitem "planted: functor and bifunctor" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    struct Count{T}                                    # fmap counts calls: breaks identity
        x::T
        n::Int
    end
    U.fmap(f, c::Count) = Count(f(c.x), c.n + 1)
    U.bimap(f, g, c::Count) = Count(g(c.x), c.n + 1)
    struct Twice{T}                                    # applies f twice, but keeps identity
        x::T
    end
    U.fmap(f, t::Twice) = f === identity ? t : Twice(f(f(t.x)))
    U.bimap(f, g, t::Twice) = (f === identity && g === identity) ? t : Twice(f(g(t.x)))
    counts = map(x -> Count(x, 0), L.ints)
    twices = map(Twice, L.ints)
    nonid = Data.SampledFrom(Function[x -> x + 1, x -> 2x])

    @test "functor: identity" in first(L.planted(() -> L.test_functor_laws(nothing, counts, L.intfns)))
    failed, passed = L.planted(() -> L.test_functor_laws(nothing, twices, nonid))
    @test "functor: composition" in failed && "functor: identity" in passed
    @test "bifunctor: identity" in first(L.planted(() -> L.test_bifunctor_laws(counts, L.intfns, L.intfns)))
    failed, passed = L.planted(() -> L.test_bifunctor_laws(twices, nonid, nonid))
    @test "bifunctor: composition" in failed && "bifunctor: identity" in passed
end

@testitem "planted: applicative" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    struct NonePure end                                # pure gives none: breaks identity, composition
    U.pure(::NonePure, x) = none(typeof(x))
    struct OffByOne end                                # pure adds 1 to numbers: breaks hom., interchange
    U.pure(::OffByOne, x) = some(x isa Int ? x + 1 : x)
    ff = Data.SampledFrom(Any[some(x -> x + 1), some(x -> 2x)])
    somes = map(some, L.ints)
    nonid = Data.SampledFrom(Function[x -> x + 1, x -> 2x])

    failed, _ = L.planted(() -> L.test_applicative_laws(NonePure(), L.ints, somes, nonid, ff))
    @test "applicative: identity" in failed && "applicative: composition" in failed
    failed, passed = L.planted(() -> L.test_applicative_laws(OffByOne(), L.ints, somes, nonid, ff))
    @test "applicative: homomorphism" in failed && "applicative: interchange" in failed
    @test "applicative: identity" in passed && "applicative: composition" in passed
end

@testitem "planted: monad" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    struct OffByOne end
    U.pure(::OffByOne, x) = some(x isa Int ? x + 1 : x)
    # a writer-like counter whose chain doubles the outer count: not associative, and its `ap`
    # disagrees with the `ap` derived from chain
    struct W{T}
        x::T
        n::Int
    end
    struct WTag end
    Base.isequal(a::W, b::W) = isequal(a.x, b.x) && a.n == b.n
    U.pure(::WTag, x) = W(x, 0)
    U.fmap(f, w::W) = W(f(w.x), w.n)
    U.chain(k, w::W) = (r = k(w.x)::W; W(r.x, 2w.n + r.n))
    U.ap(wf::W, wx::W) = W(wf.x(wx.x), 0)
    ws = map(x -> W(x, x % 3), L.ints)
    wk = Data.SampledFrom(Function[x -> W(x + 1, 1), x -> W(2x, 0), x -> W(-x, 2)])
    wff = Data.SampledFrom(Any[W(x -> x + 1, 1), W(x -> 2x, 2)])
    ff = Data.SampledFrom(Any[some(x -> x + 1)])

    failed, _ = L.planted(() -> L.test_monad_laws(OffByOne(), L.ints, map(some, L.ints), L.optfns, ff))
    @test "monad: left identity" in failed && "monad: right identity" in failed
    failed, _ = L.planted(() -> L.test_monad_laws(WTag(), L.ints, ws, wk, wff))
    @test "monad: associativity" in failed && "monad: ap is chain" in failed
end

@testitem "planted: alternative" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    struct ZeroIsSome end                              # the "empty" value is some(0)
    U.zeroalt(::ZeroIsSome, ::Type{T}) where {T} = some(zero(T))
    struct D                                           # alt subtracts: not associative
        x::Int
    end
    struct DTag end
    U.alt(a::D, b::D) = D(a.x - b.x)
    U.zeroalt(::DTag, ::Type) = D(0)
    failed, _ = L.planted(() -> L.test_alternative_laws(ZeroIsSome(), Int, L.options))
    @test "alternative: left identity" in failed && "alternative: right identity" in failed
    failed, passed = L.planted(() -> L.test_alternative_laws(DTag(), Int, map(D, L.ints)))
    @test "alternative: associativity" in failed && "alternative: right identity" in passed
end

@testitem "planted: foldable" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    # iteration is a vector's; each Base fold below disagrees with it in one way
    struct BadFold
        v::Vector{Int}
    end
    Base.iterate(b::BadFold, s...) = iterate(b.v, s...)
    Base.IteratorSize(::Type{BadFold}) = Base.SizeUnknown()          # so `collect` ignores length
    Base.length(b::BadFold) = length(b.v) + 1
    Base.foldl(op, b::BadFold; init) = foldl(op, reverse(b.v); init)
    Base.Iterators.reverse(b::BadFold) = b.v                         # foldr runs forwards
    Base.mapreduce(f, op, b::BadFold; init) = foldl(op, b.v; init)   # ignores f
    bads = map(BadFold, Data.Vectors(L.ints; min_size = 2, max_size = 4))
    failed, _ = L.planted(() -> L.test_foldable_laws(bads))
    @test failed ⊇ Set(["foldable: foldl", "foldable: foldr", "foldable: length", "foldable: mapreduce"])
end

@testitem "planted: traversable" tags = [:laws] setup = [LawKits] begin
    using ChuiTypes, Supposition
    const L = LawKits
    const U = ChuiTypes.Upstream
    struct Count                                       # traverse counts: identity, composition
        x::Int
        n::Int
    end
    U.traverse(tag, f, c::Count) = U.fmap(y -> Count(y, c.n + 1), f(c.x))
    Base.isequal(a::Count, b::Count) = a.x == b.x && a.n == b.n
    struct Peek                                        # traverse ignores f for Option only
        x::Int
    end
    U.traverse(tag::ChuiTypes.OptionTag, f, p::Peek) = U.pure(tag, p)
    U.traverse(tag, f, p::Peek) = U.fmap(Peek, f(p.x))
    nonid = Data.SampledFrom(Function[x -> some(x + 1), x -> some(2x)])
    failed, passed = L.planted(() -> L.test_traversable_laws(map(x -> Count(x, 0), L.ints), L.optfns, L.eitherfns))
    @test "traversable: identity" in failed && "traversable: composition" in failed
    @test "traversable: naturality" in passed
    failed, _ = L.planted(() -> L.test_traversable_laws(map(Peek, L.ints), nonid, L.eitherfns))
    @test "traversable: naturality" in failed
end
