@testitem "module loads" tags = [:unit] begin
    using ChuiTypes
    @test ChuiTypes isa Module
    @test nameof(ChuiTypes) == :ChuiTypes
    # Scaffold: nothing is exported yet (only the module's own name).
    @test names(ChuiTypes) == [:ChuiTypes]
end

@testitem "Aqua" tags = [:quality] begin
    using ChuiTypes, Aqua
    Aqua.test_all(ChuiTypes)
end

@testitem "ExplicitImports" tags = [:quality] begin
    using ChuiTypes, ExplicitImports
    @test check_no_implicit_imports(ChuiTypes) === nothing
    @test check_no_stale_explicit_imports(ChuiTypes) === nothing
    @test check_all_qualified_accesses_via_owners(ChuiTypes) === nothing
    @test check_all_explicit_imports_via_owners(ChuiTypes) === nothing
    # ADR-0006/0007: the *_are_public checks need Base.ispublic (Julia >= 1.11).
    if VERSION >= v"1.11"
        @test check_all_qualified_accesses_are_public(ChuiTypes) === nothing
        @test check_all_explicit_imports_are_public(ChuiTypes) === nothing
    end
end
