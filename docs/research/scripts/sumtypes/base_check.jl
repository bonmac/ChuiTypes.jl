# Base Union{Nothing,T} / Some{T}: layout and inference of a map-like chain.
println("julia ", VERSION)
for T in (
        Union{Nothing, Int}, Union{Nothing, Some{Int}}, Union{Nothing, String}, Union{Nothing, Some{Nothing}},
        Union{Int, String}, Union{Nothing, Int, Float64},
    )
    println(rpad(string(T), 34), " allocatedinline=", Base.allocatedinline(T), "  isbitsunion=", Base.isbitsunion(T))
end
# the nested-Nothing ambiguity that motivates Some{T}
f(d, k) = get(d, k, nothing)
d = Dict(:a => nothing)
println("get(Dict(:a=>nothing), :a, nothing) === get(..., :b, nothing): ", f(d, :a) === f(d, :b))
# map over Union{Nothing,T}
bmap(g, x::Nothing) = nothing
bmap(g, x) = g(x)
chain(x::Union{Nothing, Int}) = bmap(y -> y > 0 ? 2y : nothing, bmap(y -> y > 0 ? 2y : nothing, x))
println("2-step chain(::Union{Nothing,Int}) -> ", Base.return_types(chain, Tuple{Union{Nothing, Int}})[1])
v = Union{Nothing, Int}[isodd(i) ? i : nothing for i in 1:(10^6)]
s(v) = (
    t = 0; for x in v
        t += something(chain(x), 0)
    end; t
)
s(v)
println("@allocated sum over Vector{Union{Nothing,Int}} with 2-step chain = ", @allocated(s(v)))
