@testitem "Validation: constructors, accessors, layout" tags = [:unit] begin
    using ChuiTypes
    @test valid(1, String) isa Validation{String, Int}
    @test invalid("e", Int) isa Validation{String, Int}
    @test isconcretetype(Validation{String, Int})
    @test fieldnames(Validation) == (:tag, :errs, :a)
    @test fieldtype(Validation{String, Int}, :errs) == Union{Nothing, Vector{String}}
    @test isvalid(valid(1, String)) && !isinvalid(valid(1, String))
    @test isinvalid(invalid("e", Int)) && !isvalid(invalid("e", Int))
    @test errors(invalid("e", Int)) == ["e"]
    @test errors(valid(1, String)) == String[]
    @test get(valid(1, String), 0) == 1
    @test get(invalid("e", Int), 0) == 0
    # errors returns a copy: mutating it never changes the value
    v = invalid("e", Int)
    push!(errors(v), "z")
    @test errors(v) == ["e"]
end

@testitem "Validation: accumulating applicative never mutates inputs" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    a = invalid("a", typeof(identity))
    b = invalid("b", Int)
    ab = U.ap(a, b)
    @test errors(ab) == ["a", "b"]
    @test errors(a) == ["a"] && errors(b) == ["b"]
    @test ab.errs !== a.errs && ab.errs !== b.errs
    @test U.ap(valid(x -> x + 1, String), valid(1, String)) === valid(2, String)
    @test errors(U.ap(valid((x::Int) -> x, String), b)) == ["b"]
    @test U.pure(ChuiTypes.ValidationTag{String}(), 1) === valid(1, String)
    @test map(x -> x + 1, valid(1, String)) === valid(2, String)
    @test map(string, invalid("e", Int)) isa Validation{String, String}
    @test U.bimap(length, x -> x + 1, invalid("abc", Int)) == invalid(3, Int)
    @test U.bimap(length, x -> x + 1, valid(1, String)) == valid(2, Int)
    @test !hasmethod(U.chain, Tuple{Function, Validation})      # no Monad (ADR-0001 §10)
end

@testitem "Validation: semigroup, traverse, equality, show" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    struct Plus end
    U.combine(::Plus, a::Int, b::Int) = a + b
    s = ChuiTypes.ValidationSemigroup(Plus())
    @test U.combine(s, valid(1, String), valid(2, String)) === valid(3, String)
    @test errors(U.combine(s, invalid("a", Int), invalid("b", Int))) == ["a", "b"]
    @test U.combine(s, valid(1, String), invalid("b", Int)) == invalid("b", Int)
    opt(x) = x > 0 ? some(x) : none(Int)
    @test U.traverse(ChuiTypes.OptionTag(), opt, valid(1, String)) == some(valid(1, String))
    @test U.traverse(ChuiTypes.OptionTag(), opt, invalid("e", Int)) == some(invalid("e", Int))
    @test valid([1], String) == valid([1], String)
    @test hash(invalid("e", Int)) == hash(invalid("e", Float64))
    @test valid(1, Int) != invalid(1, Int)
    @test repr(valid(1, String)) == "valid(1, String)"
    @test repr(invalid("e", Int)) == "invalid(\"e\", Int64)"
    @test repr(U.ap(invalid("a", typeof(identity)), invalid("b", Int))) ==
        "Validation{String, Int64}(errors = [\"a\", \"b\"])"
    @test collect(valid(1, String)) == [1] && collect(invalid("e", Int)) == Int[]
end

@testitem "Validation: inference and allocations (valid path)" tags = [:unit] begin
    using ChuiTypes, Test
    const U = ChuiTypes.Upstream
    chain3(v) = map(x -> x * 2, U.ap(valid(x -> x + 1, String), map(x -> x - 1, v)))
    @test @inferred(chain3(valid(3, String))) === valid(6, String)
    @test @inferred(chain3(invalid("e", Int))) == invalid("e", Int)
    if Base.JLOptions().code_coverage == 0
        run(v) = foldl(+, chain3(v); init = 0)
        v = valid(3, String)
        run(v)
        @test (@allocated run(v)) == 0
    end
end
