struct Opt2{T}
    has::Bool; v::Union{Nothing, T}
end
s2(v::T) where {T} = Opt2{T}(true, v); n2(::Type{T}) where {T} = Opt2{T}(false, nothing)
Base.map(f::F, o::Opt2{T}) where {F, T} = o.has ? s2(f(o.v::T)) : n2(T)
inc(x) = x + 1
function chain!(out, v)
    @inbounds for i in eachindex(v)
        out[i] = map(inc, map(inc, map(inc, v[i])))
    end
    return out
end
vi = [isodd(i) ? s2(i) : n2(Int) for i in 1:(10^5)]; oi = similar(vi); chain!(oi, vi)
println(VERSION, " Opt2{Int}: isbitstype=", isbitstype(Opt2{Int}), " sizeof=", sizeof(Opt2{Int}), " inline=", Base.allocatedinline(Opt2{Int}), " chain allocs=", @allocated chain!(oi, vi))
println("return_types map(inc, ::Opt2{Int}) = ", Base.return_types(map, (typeof(inc), Opt2{Int})))
x = s2(nothing); y = n2(Nothing); println("Opt2{Nothing}: some(nothing).has=", x.has, " none(Nothing).has=", y.has, " distinguishable=", x.has != y.has)
