@testitem "ADR-0004: only src/upstream.jl names the upstream core package" tags = [:quality] begin
    # Blind spots (spec §8): names built at run time (`getfield(Main, Symbol(...))`, `eval`)
    # and modules reached through `Base.loaded_modules`.
    root = pkgdir(ChuiTypes)
    pat = Regex("\\b" * "Chui" * "Core" * "\\b")   # spelled in pieces so this file is not a hit
    offenders = String[]
    for dir in ("src", "ext")
        isdir(joinpath(root, dir)) || continue
        for (d, _, files) in walkdir(joinpath(root, dir)), f in files
            endswith(f, ".jl") || continue
            path = joinpath(d, f)
            relpath(path, root) == joinpath("src", "upstream.jl") && continue
            occursin(pat, read(path, String)) && push!(offenders, relpath(path, root))
        end
    end
    @test isempty(offenders)
    # the check itself sees a planted mention
    mktempdir() do tmp
        p = joinpath(tmp, "x.jl")
        write(p, "import " * "Chui" * "Core: fmap\n")
        @test occursin(pat, read(p, String))
    end
end

@testitem "ADR-0001 §1, §11: every value type is concrete" tags = [:quality] begin
    using ChuiTypes
    for T in (
            Option{Int}, Option{String}, Either{String, Int}, Validation{String, Int},
            These{Int, String}, NonEmpty{Int}, LazyList{Int},
        )
        @test isconcretetype(T)
        # every field is concrete or a small `Union{Nothing,X}` slot (ADR-0001 §2); only the
        # LazyList cell's thunk is erased (ADR-0001 §7)
        @test all(t -> isconcretetype(t) || (t isa Union && Nothing <: t), fieldtypes(T))
    end
    @test fieldtype(ChuiTypes._LazyCell{Int}, :thunk) === Any
    @test !isabstracttype(Option) && Option isa UnionAll
end

@testitem "ADR-0001 §4: the result parameter rule gives Any when inference cannot" tags = [:quality] begin
    using ChuiTypes, Test
    const C = ChuiTypes
    const U = C.Upstream
    # the three cases the ADR names
    @test C._param(Option, Union{}, 1) === Any
    @test C._param(Option, Union{Option{Int}, Option{String}}, 1) === Any
    @test C._param(Option, Any, 1) === Any
    @test C._param(Option, Option{Int}, 1) === Int
    @test C._param(Either, Either{String, Int}, 2) === Int
    @test C._valparam(Union{}) === Any && C._valparam(Any) === Any
    @test C._valparam(Either{String, Int}) === Int && C._valparam(Vector{Int}) === Any
    # end to end: `f` always throws, or returns different Option types
    alwaysthrows(x::Int) = throw(ArgumentError("no"))
    @test U.chain(alwaysthrows, none(Int)) isa Option{Any}
    mixed(x) = x > 0 ? some(1) : some("a")
    @test U.chain(mixed, none(Int)) isa Option{Any}
    @test U.chain(mixed, some(1)) === some(1)
    # never asserted: a correct program never throws because of the inferred parameter
    @test map(x -> x, none(Any)) isa Option{Any}
end

@testitem "ADR-0001 §11: map/chain/fold chains infer concretely" tags = [:quality] begin
    using ChuiTypes, Test
    const U = ChuiTypes.Upstream
    half(x) = iseven(x) ? some(x ÷ 2) : none(Int)
    opt(o) = foldl(+, U.chain(half, map(x -> x * 4, U.chain(half, o))); init = 0)
    @test @inferred(opt(some(4))) == 4
    pos(x) = x > 0 ? right(String, x) : left("neg", Int)
    eit(e) = foldl(+, U.chain(pos, map(x -> x - 1, U.chain(pos, e))); init = 0)
    @test @inferred(eit(right(String, 3))) == 2
    val(v) = foldl(+, map(x -> x + 1, U.ap(valid(x -> 2x, String), v)); init = 0)
    @test @inferred(val(valid(1, String))) == 3
    @test @inferred(val(invalid("e", Int))) == 0
    ne(n) = foldl(+, U.chain(x -> nonempty(x, x), map(x -> x + 1, n)))
    @test @inferred(ne(nonempty(1, 2))) == 10
end
