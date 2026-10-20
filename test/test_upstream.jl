@testitem "Upstream: stand-ins are generic functions of the adapter module" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    @test U isa Module && parentmodule(U) === ChuiTypes
    for n in (:fmap, :pure, :ap, :chain, :alt, :zeroalt, :bimap, :traverse, :combine, :neutral, :default_monoid, :constructorclass)
        f = getfield(U, n)
        @test f isa Function && parentmodule(f) === U
    end
    # every constructor class maps to its owned tag
    @test U.constructorclass(Validation{String, Int}) === ChuiTypes.ValidationTag{String}()
    @test U.constructorclass(These{Int, String}) === ChuiTypes.TheseTag{Int}()
    @test U.constructorclass(NonEmpty{Int}) === ChuiTypes.NonEmptyTag()
    @test U.constructorclass(LazyList{Int}) === ChuiTypes.LazyListTag()
end

@testitem "Upstream: default_monoid without a declaration throws ArgumentError" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: both
    const U = ChuiTypes.Upstream
    @test_throws ArgumentError U.default_monoid(Int)
    # These' Monad needs one for its first parameter
    @test_throws ArgumentError U.chain(x -> both(1, x), both(1, 2))
end
