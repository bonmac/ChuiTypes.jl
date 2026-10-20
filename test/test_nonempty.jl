@testitem "NonEmpty: constructors, accessors, layout" tags = [:unit] begin
    using ChuiTypes
    @test nonempty(1) isa NonEmpty{Int}
    @test nonempty(1, 2, 3) isa NonEmpty{Int}
    @test nonempty(1, 2.5) isa NonEmpty{Float64}
    @test isconcretetype(NonEmpty{Int})
    @test fieldnames(NonEmpty) == (:head, :tail)
    ne = nonempty(1, 2, 3)
    @test first(ne) == 1 && last(ne) == 3 && last(nonempty(7)) == 7
    @test length(ne) == 3 && ne[2] == 2 && ne[3] == 3
    @test_throws BoundsError ne[4]
    @test_throws BoundsError ne[0]
    @test collect(ne) == [1, 2, 3]
    @test eltype(NonEmpty{String}) == String
    @test foldl(-, ne) == -4 && foldr(-, ne) == 2
    @test mapreduce(x -> 2x, +, ne) == 12
end

@testitem "NonEmpty: functor, monad, applicative, semigroup" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    ne = nonempty(1, 2, 3)
    @test map(x -> x * 10, ne) == nonempty(10, 20, 30)
    @test map(string, nonempty(1)) isa NonEmpty{String}
    @test U.chain(x -> nonempty(x, -x), nonempty(1, 2)) == nonempty(1, -1, 2, -2)
    @test U.pure(ChuiTypes.NonEmptyTag(), 1) == nonempty(1)
    @test U.ap(nonempty(x -> x + 1, x -> x * 2), nonempty(10, 20)) == nonempty(11, 21, 20, 40)
    s = ChuiTypes.NonEmptySemigroup()
    a, b = nonempty(1, 2), nonempty(3)
    @test U.combine(s, a, b) == nonempty(1, 2, 3)
    @test a == nonempty(1, 2) && b == nonempty(3)          # inputs unchanged
    @test U.combine(s, a, b).tail !== a.tail
    opt(x) = x > 0 ? some(x) : none(Int)
    @test U.traverse(ChuiTypes.OptionTag(), opt, ne) == some(ne)
    @test U.traverse(ChuiTypes.OptionTag(), opt, nonempty(1, -1)) == none(NonEmpty{Int})
end

@testitem "NonEmpty: equality, hash, show, inference" tags = [:unit] begin
    using ChuiTypes, Test
    const U = ChuiTypes.Upstream
    @test nonempty([1], [2]) == nonempty([1], [2])
    @test hash(nonempty(1, 2)) == hash(nonempty(1, 2))
    @test nonempty(1, 2) != nonempty(1)
    @test isequal(nonempty(NaN), nonempty(NaN))
    @test repr(nonempty(1, 2, 3)) == "nonempty(1, 2, 3)"
    @test repr(nonempty("a")) == "nonempty(\"a\")"
    @test @inferred(map(x -> x + 1, nonempty(1, 2))) == nonempty(2, 3)
    @test @inferred(U.chain(x -> nonempty(x, x), nonempty(1, 2))) == nonempty(1, 1, 2, 2)
    @test @inferred(foldl(+, nonempty(1, 2))) == 3
end

@testitem "NonEmpty: map and chain never convert element values (review BLOCKER-2)" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    ne = nonempty(1, 2)
    f = x -> x == 1 ? 1 : 2.5
    g = x -> x isa Int
    @test map(x -> g(f(x)), ne) == map(g, map(f, ne))
    @test collect(map(f, ne)) == Real[1, 2.5] && first(map(f, ne)) isa Int
    big = map(x -> x == 1 ? 2^60 + 1 : 0.5, ne)
    @test first(big) === 2^60 + 1
    @test eltype(map(f, ne)) == Real
    # the element type no longer depends on the tail's length (empty tail: inference, ADR-0001 §4)
    @test eltype(map(f, nonempty(1))) == Real && first(map(f, nonempty(1))) === 1
    @test collect(U.chain(x -> x == 1 ? nonempty(1) : nonempty(2.5), ne)) == Real[1, 2.5]
    @test first(U.chain(x -> x == 1 ? nonempty(1) : nonempty(2.5), ne)) isa Int
    tr = U.traverse(ChuiTypes.OptionTag(), x -> some(f(x)), ne)
    @test first(get(tr, nothing)) isa Int
    @test_throws ArgumentError ne[true]                      # Bool is not an index (review NIT-4)
    # traverse is linear: a long tail completes and keeps order
    long = nonempty(0, 1:20_000...)
    @test get(U.traverse(ChuiTypes.OptionTag(), some, long), nothing) == long
end
