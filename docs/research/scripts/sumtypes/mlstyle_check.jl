# What MLStyle @data and Expronicon @adt generate for an Option-like type.
using MLStyle; using Expronicon.ADT: @adt
println("julia ", VERSION)
# 1. generic nullary variant: rejected by MLStyle
try
    eval(
        :(
            @data GOpt{T} begin
                GNone
                GSome{T}(T)
            end
        )
    )
catch e
    println("MLStyle generic nullary variant: ", sprint(showerror, e)[1:min(end, 110)])
end
# 2. monomorphic version
@data MLOpt begin
    MLNone
    MLSome(Int)
end
println(
    "MLStyle: isabstracttype(MLOpt)=", isabstracttype(MLOpt), "  MLSome <: MLOpt: ", MLSome <: MLOpt,
    "  typeof(MLNone) <: MLOpt: ", typeof(MLNone) <: MLOpt
)
mk(b) = b ? MLSome(1) : MLNone
println(
    "MLStyle: mk(::Bool) inferred ", Base.return_types(mk, Tuple{Bool})[1],
    "; comprehension eltype = ", eltype([mk(isodd(i)) for i in 1:4])
)
@adt EOpt begin
    ENone
    struct ESome
        x::Int
    end
end
println(
    "Expronicon @adt: isconcretetype(EOpt)=", isconcretetype(EOpt), " fieldtypes=", fieldtypes(EOpt),
    " sizeof=", sizeof(EOpt), " isbitstype=", isbitstype(EOpt)
)
