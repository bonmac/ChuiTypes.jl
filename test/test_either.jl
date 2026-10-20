@testitem "Either: constructors, accessors, layout" tags = [:unit] begin
    using ChuiTypes
    @test left("e", Int) isa Either{String, Int}
    @test right(String, 1) isa Either{String, Int}
    @test isconcretetype(Either{String, Int})
    @test fieldnames(Either) == (:tag, :l, :r)
    @test isleft(left("e", Int)) && !isright(left("e", Int))
    @test isright(right(String, 1))
    @test fromleft(left("e", Int)) == "e"
    @test fromright(right(String, 1)) == 1
    @test_throws ArgumentError fromleft(right(String, 1))
    @test_throws ArgumentError fromright(left("e", Int))
    @test get(right(String, 1), 0) == 1
    @test get(left("e", Int), 0) == 0
    @test left(nothing, Int) != right(Nothing, nothing)
    # an abstract left parameter is kept by map (not narrowed to the payload's type)
    @test map(x -> x + 1, left(1, Int)) isa Either{Int, Int}
    @test map(x -> x + 1, right(Any, 1)) isa Either{Any, Int}
end

@testitem "Either: Base integration, equality, show" tags = [:unit] begin
    using ChuiTypes
    @test collect(right(String, 2)) == [2]
    @test collect(left("e", Int)) == Int[]
    @test foldl(+, right(String, 2); init = 1) == 3
    @test foldr(+, left("e", Int); init = 1) == 1
    @test map(x -> x * 2, right(String, 2)) === right(String, 4)
    @test map(string, left(:e, Int)) == left(:e, String)
    @test map(string, left(:e, Int)) isa Either{Symbol, String}
    @test right(String, [1]) == right(String, [1])
    @test hash(right(String, [1])) == hash(right(String, [1]))
    @test left("e", Int) == left("e", Float64)
    @test left(1, Int) != right(Int, 1)
    @test hash(left(1, Int)) != hash(right(Int, 1))
    @test repr(left("e", Int)) == "left(\"e\", Int64)"
    @test repr(right(String, 1)) == "right(String, 1)"
end

@testitem "Either: monad, applicative, bifunctor, traverse" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    const T = ChuiTypes.EitherTag{String}()
    pos(x) = x > 0 ? right(String, x) : left("neg", Int)
    @test U.chain(pos, right(String, 1)) === right(String, 1)
    @test U.chain(pos, right(String, -1)) == left("neg", Int)
    @test U.chain(pos, left("x", Int)) == left("x", Int)
    @test U.pure(T, 1) === right(String, 1)
    @test U.ap(right(String, x -> x + 1), right(String, 1)) === right(String, 2)
    @test U.ap(left("f", typeof(identity)), left("x", Int)) == left("f", Any)
    @test U.ap(right(String, (x::Int) -> x + 1), left("x", Int)) == left("x", Int)
    @test U.bimap(length, x -> x + 1, left("abc", Int)) == left(3, Int)
    @test U.bimap(length, x -> x + 1, right(String, 1)) == right(Int, 2)
    @test U.constructorclass(Either{String, Int}) === T
    opt(x) = x > 0 ? some(x) : none(Int)
    @test U.traverse(ChuiTypes.OptionTag(), opt, right(String, 1)) == some(right(String, 1))
    @test U.traverse(ChuiTypes.OptionTag(), opt, right(String, 0)) == none(Either{String, Int})
    @test U.traverse(ChuiTypes.OptionTag(), opt, left("e", Int)) == some(left("e", Int))
end

@testitem "Either: inference and allocations" tags = [:unit] begin
    using ChuiTypes, Test
    const U = ChuiTypes.Upstream
    pos(x) = x > 0 ? right(String, x) : left("neg", Int)
    chain3(e) = U.chain(pos, map(x -> x - 1, U.chain(pos, e)))
    @test @inferred(chain3(right(String, 3))) === right(String, 2)
    @test @inferred(chain3(left("x", Int))) == left("x", Int)
    @test @inferred(U.bimap(length, x -> x + 1, right(String, 1))) == right(Int, 2)
    if Base.JLOptions().code_coverage == 0
        allocs(f, x) = (f(x); @allocated f(x))       # inside a function (see test_option.jl)
        run(e) = foldl(+, chain3(e); init = 0)
        @test allocs(run, right(String, 3)) == 0
        @test allocs(run, right(String, -3)) == 0
        @test allocs(run, left("x", Int)) == 0
    end
end

@testitem "Either/These: chain keeps the fixed parameter (review NIT-1)" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: both, that
    const U = ChuiTypes.Upstream
    @test_throws TypeError U.chain(x -> right(Int, x), right(String, 1))
    @test_throws TypeError U.chain(x -> that(String, x), that(Int, 1))
end
