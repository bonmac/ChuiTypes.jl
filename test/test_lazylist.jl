@testitem "LazyList: constructors and iteration" tags = [:unit] begin
    using ChuiTypes
    @test lazynil(Int) isa LazyList{Int}
    @test isempty(lazynil(Int)) && collect(lazynil(Int)) == Int[]
    @test collect(lazycons(1, lazycons(2, lazynil(Int)))) == [1, 2]
    @test collect(lazylist([1, 2, 3])) == [1, 2, 3]
    @test lazylist(1:3) isa LazyList{Int}
    @test length(lazylist(1:4)) == 4
    @test eltype(LazyList{String}) == String
    @test Base.IteratorSize(LazyList{Int}) == Base.SizeUnknown()
    @test foldl(-, lazylist(1:3)) == -4 && foldr(-, lazylist(1:3)) == 2
    @test first(lazylist(5:9)) == 5
end

@testitem "LazyList: laziness, infinity and memoisation" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    nat = lazylist(Iterators.countfrom(1))
    @test collect(Iterators.take(nat, 3)) == [1, 2, 3]
    @test collect(Iterators.take(map(x -> x^2, nat), 4)) == [1, 4, 9, 16]
    calls = Ref(0)
    sq = map(x -> (calls[] += 1; x^2), lazylist(1:5))
    @test calls[] == 0                                   # map is lazy
    @test collect(Iterators.take(sq, 2)) == [1, 4]
    @test calls[] == 2
    @test collect(sq) == [1, 4, 9, 16, 25]
    @test collect(sq) == [1, 4, 9, 16, 25]
    @test calls[] == 5                                   # each cell is forced once
    ones_ = lazycons(1, () -> ones_)                     # a cyclic infinite list
    @test collect(Iterators.take(ones_, 3)) == [1, 1, 1]
    # a deferred tail is not called until needed
    tailcalls = Ref(0)
    l = lazycons(1, () -> (tailcalls[] += 1; lazycons(2, lazynil(Int))))
    @test first(l) == 1 && tailcalls[] == 0
    @test collect(l) == [1, 2] && tailcalls[] == 1
    evens = U.chain(x -> iseven(x) ? lazycons(x, lazynil(Int)) : lazynil(Int), nat)
    @test collect(Iterators.take(evens, 3)) == [2, 4, 6]
    @test collect(Iterators.take(U.alt(lazylist(1:2), nat), 4)) == [1, 2, 1, 2]
end

@testitem "LazyList: monad, applicative, alternative, monoid" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    l = lazylist([1, 2])
    @test collect(U.chain(x -> lazylist([x, -x]), l)) == [1, -1, 2, -2]
    @test collect(U.pure(ChuiTypes.LazyListTag(), 3)) == [3]
    fs = lazylist([x -> x + 1, x -> x * 2])
    @test collect(U.ap(fs, lazylist([10, 20]))) == [11, 21, 20, 40]
    @test collect(U.alt(l, lazylist([3]))) == [1, 2, 3]
    @test collect(U.zeroalt(ChuiTypes.LazyListTag(), Int)) == Int[]
    m = ChuiTypes.LazyListMonoid(Int)
    @test collect(U.combine(m, l, lazylist([3]))) == [1, 2, 3]
    @test isempty(U.neutral(m)) && U.neutral(m) isa LazyList{Int}
    @test U.neutral(m).cell !== U.neutral(m).cell             # fresh per call
end

@testitem "LazyList: equality, hash, show" tags = [:unit] begin
    using ChuiTypes
    @test lazylist([1, 2]) == lazylist([1, 2])
    @test lazylist([1, 2]) != lazylist([1])
    @test lazylist([1]) != lazylist([1, 2])
    @test isequal(lazylist([NaN]), lazylist([NaN]))
    @test hash(lazylist([1, 2])) == hash(lazylist([1, 2]))
    @test lazynil(Int) == lazynil(String)
    l = lazylist([1, 2, 3])
    @test repr(l) == "LazyList{Int64}(…)"                      # nothing forced yet
    collect(l)
    @test repr(l) == "lazylist([1, 2, 3])"
    @test repr(lazynil(Int)) == "lazynil(Int64)"
    m = lazylist(Iterators.countfrom(1))
    collect(Iterators.take(m, 2))
    @test startswith(repr(m), "LazyList{Int64}([1, 2")
end
