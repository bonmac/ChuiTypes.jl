@testitem "Option: constructors and layout" tags = [:unit] begin
    using ChuiTypes
    @test some(1) isa Option{Int}
    @test none(Int) isa Option{Int}
    @test isconcretetype(Option{Int}) && isconcretetype(Option{String})
    @test fieldnames(Option) == (:has, :v)
    @test fieldtype(Option{Int}, :v) == Union{Nothing, Int}
    # stored inline: 24 bytes on 64-bit (ADR-0001 Consequences); a union field is never isbits
    Sys.WORD_SIZE == 64 && @test sizeof(Option{Int}) == 24
    @test issome(some(1)) && !isnone(some(1))
    @test isnone(none(Int)) && !issome(none(Int))
    # Option{Nothing} still tells some(nothing) from none(Nothing) (ADR-0001 Context)
    @test issome(some(nothing)) && isnone(none(Nothing))
    @test some(nothing) != none(Nothing)
end

@testitem "Option: accessors and Base integration" tags = [:unit] begin
    using ChuiTypes
    @test get(some(2), 0) == 2
    @test get(none(Int), 0) == 0
    @test collect(some(3)) == [3]
    @test collect(none(Int)) == Int[]
    @test length(some(3)) == 1 && length(none(Int)) == 0
    @test eltype(Option{String}) == String
    @test foldl(+, some(3); init = 10) == 13
    @test foldr(+, some(3); init = 10) == 13
    @test foldl(+, none(Int); init = 10) == 10
    @test mapreduce(x -> 2x, +, some(4); init = 0) == 8
    @test map(x -> x + 1, some(1)) === some(2)
    @test map(x -> x + 1, none(Int)) === none(Int)
    @test map(string, none(Int)) isa Option{String}
end

@testitem "Option: equality, hash, show" tags = [:unit] begin
    using ChuiTypes
    @test some([1]) == some([1])
    @test isequal(some([1]), some([1]))
    @test hash(some([1])) == hash(some([1]))
    @test none(Int) == none(String)        # active slots only (spec §5)
    @test hash(none(Int)) == hash(none(String))
    @test some(1) != none(Int)
    @test isequal(some(NaN), some(NaN)) && some(NaN) != some(NaN)
    @test ismissing(some(missing) == some(missing))
    @test repr(some(1)) == "some(1)"
    @test repr(none(Int)) == "none(Int64)"
    @test repr(some("a")) == "some(\"a\")"
end

@testitem "Option: monad, applicative, alternative" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    half(x) = iseven(x) ? some(x ÷ 2) : none(Int)
    @test U.chain(half, some(4)) === some(2)
    @test U.chain(half, some(3)) === none(Int)
    @test U.chain(half, none(Int)) === none(Int)
    @test U.fmap(x -> x * 2, some(2)) === some(4)
    @test U.pure(ChuiTypes.OptionTag(), 1) === some(1)
    @test U.ap(some(x -> x + 1), some(1)) === some(2)
    @test U.ap(none(typeof(identity)), some(1)) isa Option
    @test isnone(U.ap(some(x -> x + 1), none(Int)))
    @test U.alt(some(1), some(2)) === some(1)
    @test U.alt(none(Int), some(2)) === some(2)
    @test U.zeroalt(ChuiTypes.OptionTag(), Int) === none(Int)
    @test U.constructorclass(Option{Int}) === ChuiTypes.OptionTag()
end

@testitem "Option: monoid lifted from a semigroup" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    struct Plus end
    U.combine(::Plus, a::Int, b::Int) = a + b
    m = ChuiTypes.OptionMonoid(Plus(), Int)
    @test U.combine(m, some(1), some(2)) === some(3)
    @test U.combine(m, none(Int), some(2)) === some(2)
    @test U.combine(m, some(1), none(Int)) === some(1)
    @test U.neutral(m) === none(Int)
end

@testitem "Option: traverse" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    f(x) = x > 0 ? right(String, x) : left("neg", Int)
    @test U.traverse(ChuiTypes.EitherTag{String}(), f, some(1)) == right(String, some(1))
    @test U.traverse(ChuiTypes.EitherTag{String}(), f, some(-1)) == left("neg", Option{Int})
    @test U.traverse(ChuiTypes.EitherTag{String}(), f, none(Int)) === right(String, none(Int))
end

@testitem "Option: inference and allocations" tags = [:unit] begin
    using ChuiTypes, Test
    const U = ChuiTypes.Upstream
    half(x) = iseven(x) ? some(x ÷ 2) : none(Int)
    chain3(o) = U.chain(half, map(x -> x + 1, U.chain(half, o)))
    @test @inferred(chain3(some(8))) === none(Int)
    @test @inferred(map(x -> x + 1, none(Int))) === none(Int)
    @test @inferred(foldl(+, some(1); init = 0)) == 1
    s(x) = some(string(x, "!"))
    chainS(o) = U.chain(y -> some(y * "?"), map(identity, o))
    @test @inferred(chainS(some("a"))) == some("a?")
    if Base.JLOptions().code_coverage == 0
        # measured inside a function: a test item's top-level thunk allocates on 1.10
        allocs(f, x) = (f(x); @allocated f(x))
        run_int(o) = foldl(+, chain3(o); init = 0)
        @test allocs(run_int, some(8)) == 0
        @test allocs(run_int, some(3)) == 0
        @test allocs(run_int, none(Int)) == 0
        # a String chain whose functions build no new strings (`*` would allocate by itself)
        nonblank(y) = isempty(y) ? none(String) : some(y)
        lenS(o) = foldl((a, x) -> a + ncodeunits(x), U.chain(nonblank, map(identity, U.chain(nonblank, o))); init = 0)
        @test allocs(lenS, some("abc")) == 0
        @test allocs(lenS, none(String)) == 0
    end
end
