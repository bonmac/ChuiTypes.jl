@testitem "CT-003 no Base collisions" tags = [:unit] begin
    # contracts/chui-types.md CT-003 (stable): every exported name that Base, Core or a loaded
    # standard library exports IS that module's binding; IO, Task, Ref and Some, if exported,
    # are Base/Core's. Same check as CC-010.
    using ChuiTypes, Statistics, LinearAlgebra, Dates, Random, Test
    function collisions(M::Module, others)
        return [
            n for n in names(M) if n !== nameof(M) && Base.isexported(M, n) &&
                any(O -> Base.isexported(O, n) && isdefined(O, n) && getfield(O, n) !== getfield(M, n), others)
        ]
    end
    stdlibs = [
        m for m in values(Base.loaded_modules) if
            m isa Module && startswith(pathof(m) === nothing ? "" : pathof(m), Sys.STDLIB)
    ]
    others = unique!(Module[Base, Core, Statistics, LinearAlgebra, Dates, Random, Test, stdlibs...])
    @test length(others) >= 7
    @test collisions(ChuiTypes, others) == Symbol[]
    for n in (:IO, :Task, :Ref, :Some)
        if Base.isexported(ChuiTypes, n)
            @test getfield(ChuiTypes, n) === getfield(Base, n)
        end
    end
    @test all(n -> length(string(n)) > 1, names(ChuiTypes))     # no single-letter export
    # the check catches a planted collision
    @eval module _BadCT003
    export identity
    identity(x) = :mine
    end
    @test collisions(_BadCT003, others) == [:identity]
end
