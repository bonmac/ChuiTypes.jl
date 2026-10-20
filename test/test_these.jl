@testitem "These: constructors, accessors, layout" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: this, that, both, isthis, isthat, isboth, here, there
    @test this(1, String) isa These{Int, String}
    @test that(Int, "b") isa These{Int, String}
    @test both(1, "b") isa These{Int, String}
    @test isconcretetype(These{Int, String})
    @test fieldnames(These) == (:tag, :a, :b)
    @test isthis(this(1, String)) && isthat(that(Int, "b")) && isboth(both(1, "b"))
    @test here(this(1, String)) === some(1)
    @test here(that(Int, "b")) === none(Int)
    @test there(both(1, "b")) == some("b")
    @test there(this(1, String)) == none(String)
    @test !Base.isexported(ChuiTypes, :this) && !Base.isexported(ChuiTypes, :both)
    if VERSION >= v"1.11"
        @test all(n -> Base.ispublic(ChuiTypes, n), (:this, :that, :both, :here, :there))
    end
end

@testitem "These: functor, bifunctor, foldable, equality, show" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: this, that, both
    const U = ChuiTypes.Upstream
    @test map(x -> x + 1, both("a", 1)) == both("a", 2)
    @test map(x -> x + 1, this("a", Int)) == this("a", Int)
    @test map(string, this("a", Int)) isa These{String, String}
    @test map(x -> x + 1, that(Any, 1)) isa These{Any, Int}
    @test U.bimap(length, x -> x + 1, both("ab", 1)) == both(2, 2)
    @test U.bimap(length, x -> x + 1, that(String, 1)) == that(Int, 2)
    @test collect(both("a", 1)) == [1] && collect(this("a", Int)) == Int[]
    @test both("a", [1]) == both("a", [1])
    @test hash(both("a", [1])) == hash(both("a", [1]))
    @test this(1, Int) != that(Int, 1)
    @test repr(this(1, String)) == "ChuiTypes.this(1, String)"
    @test repr(that(Int, "b")) == "ChuiTypes.that(Int64, \"b\")"
    @test repr(both(1, "b")) == "ChuiTypes.both(1, \"b\")"
end

@testitem "These: applicative and monad combine with default_monoid" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: this, that, both
    const U = ChuiTypes.Upstream
    struct Log
        xs::Vector{String}
    end
    Base.:(==)(a::Log, b::Log) = a.xs == b.xs
    struct LogM end
    U.combine(::LogM, a::Log, b::Log) = Log(vcat(a.xs, b.xs))
    U.default_monoid(::Type{Log}) = LogM()
    T = ChuiTypes.TheseTag{Log}()
    @test U.pure(T, 1) == that(Log, 1)
    f(x) = x > 0 ? both(Log(["pos"]), x) : this(Log(["neg"]), Int)
    @test U.chain(f, both(Log(["a"]), 1)) == both(Log(["a", "pos"]), 1)
    @test U.chain(f, both(Log(["a"]), -1)) == this(Log(["a", "neg"]), Int)
    @test U.chain(f, that(Log, 2)) == both(Log(["pos"]), 2)
    @test U.chain(f, this(Log(["x"]), Int)) == this(Log(["x"]), Int)
    @test U.ap(both(Log(["f"]), x -> x + 1), both(Log(["x"]), 1)) == both(Log(["f", "x"]), 2)
    @test U.ap(both(Log(["f"]), (x::Int) -> x), this(Log(["x"]), Int)) == this(Log(["f", "x"]), Int)
    @test U.ap(that(Log, x -> x + 1), that(Log, 1)) == that(Log, 2)
    opt(x) = x > 0 ? some(x) : none(Int)
    @test U.traverse(ChuiTypes.OptionTag(), opt, both(Log(["a"]), 1)) == some(both(Log(["a"]), 1))
    @test U.traverse(ChuiTypes.OptionTag(), opt, this(Log(["a"]), Int)) == some(this(Log(["a"]), Int))
end

@testitem "These: inference" tags = [:unit] begin
    using ChuiTypes, Test
    using ChuiTypes: this, that, both
    const U = ChuiTypes.Upstream
    @test @inferred(map(x -> x + 1, both("a", 1))) == both("a", 2)
    @test @inferred(map(x -> x + 1, this("a", Int))) == this("a", Int)
    @test @inferred(U.bimap(length, x -> x + 1, both("ab", 1))) == both(2, 2)
end
