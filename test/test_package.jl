@testitem "module loads" tags = [:unit] begin
    using ChuiTypes
    @test ChuiTypes isa Module
    @test nameof(ChuiTypes) == :ChuiTypes
end

@testitem "exported, public and internal names" tags = [:unit] begin
    using ChuiTypes
    exported = Set(
        [
            :Option, :some, :none, :issome, :isnone,
            :Either, :left, :right, :isleft, :isright, :fromleft, :fromright,
            :Validation, :valid, :invalid, :isinvalid, :errors,
            :These, :NonEmpty, :nonempty, :LazyList, :lazylist, :lazycons, :lazynil,
        ]
    )
    public_only = Set([:this, :that, :both, :isthis, :isthat, :isboth, :here, :there])
    @test Set(filter(n -> Base.isexported(ChuiTypes, n), names(ChuiTypes))) == exported ∪ Set([:ChuiTypes])
    if VERSION >= v"1.11"
        @test Set(names(ChuiTypes)) == exported ∪ public_only ∪ Set([:ChuiTypes])
    end
    # ADR-0004 §4: no typeclass operation name is exported or public before the upstream names it
    for n in (:fmap, :pure, :ap, :chain, :alt, :zeroalt, :bimap, :traverse, :combine, :neutral, :Upstream)
        @test !Base.isexported(ChuiTypes, n)
        VERSION >= v"1.11" && @test !Base.ispublic(ChuiTypes, n)
    end
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
    # ADR-0001 §4: `Base.promote_op` is the documented, non-public exception. `Base.SizeUnknown`
    # is the documented value of the public `Base.IteratorSize`, not itself marked public.
    if VERSION >= v"1.11"
        @test check_all_qualified_accesses_are_public(ChuiTypes; ignore = (:promote_op, :SizeUnknown)) === nothing
        @test check_all_explicit_imports_are_public(ChuiTypes) === nothing
    end
end
