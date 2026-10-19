struct _None end
struct _Some{T}
    v::T
end
struct Option{T}
    x::Union{_None, _Some{T}}
end
some(v::T) where {T} = Option{T}(_Some{T}(v))
none(::Type{T}) where {T} = Option{T}(_None())
Base.map(f::F, o::Option{T}) where {F, T} = (x = o.x; x isa _Some ? some(f(x.v)) : none(T))
struct Opt2{T}
    has::Bool; v::Union{Nothing, T}
end
s2(v::T) where {T} = Opt2{T}(true, v)
n2(::Type{T}) where {T} = Opt2{T}(false, nothing)
Base.map(f::F, o::Opt2{T}) where {F, T} = o.has ? s2(f(something(o.v))) : n2(T)
id(s) = s
function chain!(out, v)
    @inbounds for i in eachindex(v)
        out[i] = map(id, map(id, map(id, v[i])))
    end
    return out
end
strs = [string(i) for i in 1:(10^5)]
vo = [isodd(i) ? some(strs[i]) : none(String) for i in 1:(10^5)]; oo = similar(vo)
v2 = [isodd(i) ? s2(strs[i]) : n2(String) for i in 1:(10^5)]; o2 = similar(v2)
chain!(oo, vo); chain!(o2, v2)
println("VERSION ", VERSION, " sizeof Opt2{String}=", sizeof(Opt2{String}))
println("wrapped Option{String} chain! allocs=", @allocated chain!(oo, vo))
println("two-slot Opt2{String} chain! allocs=", @allocated chain!(o2, v2))
vi = [isodd(i) ? some(i) : none(Int) for i in 1:(10^5)]; oi = similar(vi)
chain!(oi, vi); println("wrapped Option{Int} chain! allocs=", @allocated chain!(oi, vi))
# Vector{Any}-element: nested Option{Option{Int}}
nn = some(some(1)); println("Option{Option{Int}} isbitstype=", isbitstype(typeof(nn)), " sizeof=", sizeof(typeof(nn)))
