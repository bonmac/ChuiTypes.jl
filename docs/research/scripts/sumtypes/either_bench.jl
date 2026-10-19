# Either{L=String, R=Int} encodings: inference, allocation, layout, benchmark.
using BenchmarkTools, Random, Printf
using SumTypes
using Moshi.Data: @data
using Moshi.Match: @match
println("julia ", VERSION)
BenchmarkTools.DEFAULT_PARAMETERS.seconds = 2

const MSG = "bad input"   # one shared String: Left payloads do not allocate per element

# (a) tagged struct; both payload slots are Union{Nothing,X} because Julia cannot leave a
#     *middle* field undefined, and there is no generic dummy value for an arbitrary R.
struct TEither{L, R}
    isright::Bool
    l::Union{Nothing, L}
    r::Union{Nothing, R}
end
a_right(::Type{L}, x::R) where {L, R} = TEither{L, R}(true, nothing, x)
a_left(x::L, ::Type{R}) where {L, R} = TEither{L, R}(false, x, nothing)
a_fold(fl, fr, e::TEither) = e.isright ? fr(e.r::Some_r(e)) : fl(e.l::Some_l(e))
Some_r(::TEither{L, R}) where {L, R} = R
Some_l(::TEither{L, R}) where {L, R} = L
a_map(f, e::TEither{L, R}) where {L, R} = (
    S = Core.Compiler.return_type(f, Tuple{R});
    e.isright ? TEither{L, S}(true, nothing, f(e.r::R)) : TEither{L, S}(false, e.l, nothing)
)
a_flatmap(f, e::TEither{L, R}) where {L, R} = (
    S = Core.Compiler.return_type(f, Tuple{R});
    e.isright ? f(e.r::R)::S : S(false, e.l, nothing)
)

# (b) bare union
struct BLeft{L}
    value::L
end
struct BRight{R}
    value::R
end
b_right(::Type, x) = BRight(x)
b_left(x, ::Type) = BLeft(x)
b_fold(fl, fr, e::BLeft) = fl(e.value)
b_fold(fl, fr, e::BRight) = fr(e.value)
b_map(f, e::BLeft) = e
b_map(f, e::BRight) = BRight(f(e.value))
b_flatmap(f, e::BLeft) = e
b_flatmap(f, e::BRight) = f(e.value)

# (c) abstract supertype
abstract type CEither{L, R} end
struct CLeft{L} <: CEither{L, Union{}}
    value::L
end
struct CRight{R} <: CEither{Union{}, R}
    value::R
end
c_right(::Type, x) = CRight(x)
c_left(x, ::Type) = CLeft(x)
c_fold(fl, fr, e::CLeft) = fl(e.value)
c_fold(fl, fr, e::CRight) = fr(e.value)
c_map(f, e::CLeft) = e
c_map(f, e::CRight) = CRight(f(e.value))
c_flatmap(f, e::CLeft) = e
c_flatmap(f, e::CRight) = f(e.value)

# (e) wrapped union
struct WLeft{L}
    value::L
end
struct WRight{R}
    value::R
end
struct WEither{L, R}
    x::Union{WLeft{L}, WRight{R}}
end
w_right(::Type{L}, x::R) where {L, R} = WEither{L, R}(WRight(x))
w_left(x::L, ::Type{R}) where {L, R} = WEither{L, R}(WLeft(x))
w_fold(fl, fr, e::WEither) = (x = e.x; x isa WRight ? fr(x.value) : fl(x.value))
w_map(f, e::WEither{L, R}) where {L, R} = (
    S = Core.Compiler.return_type(f, Tuple{R}); x = e.x;
    x isa WRight ? WEither{L, S}(WRight{S}(f(x.value))) : WEither{L, S}(x)
)
w_flatmap(f, e::WEither{L, R}) where {L, R} = (
    S = Core.Compiler.return_type(f, Tuple{R}); x = e.x;
    x isa WRight ? f(x.value)::S : S(x)
)

# (d1) SumTypes
@sum_type SEither{L, R} :hidden begin
    SLeft{L}(::L)
    SRight{R}(::R)
end
s_right(::Type{L}, x::R) where {L, R} = SEither{L, R}(SEither'.SRight(x))
s_left(x::L, ::Type{R}) where {L, R} = SEither{L, R}(SEither'.SLeft(x))
s_fold(fl, fr, e::SEither) = @cases e begin
    SLeft(x) => fl(x)
    SRight(x) => fr(x)
end
s_map(f, e::SEither{L, R}) where {L, R} = (
    S = Core.Compiler.return_type(f, Tuple{R});
    @cases e begin
        SLeft(x) => SEither{L, S}(SEither'.SLeft(x))
        SRight(x) => SEither{L, S}(SEither'.SRight(f(x)))
    end
)
s_flatmap(f, e::SEither{L, R}) where {L, R} = (
    S = Core.Compiler.return_type(f, Tuple{R});
    @cases e begin
        SLeft(x) => S(SEither'.SLeft(x))
        SRight(x) => f(x)::S
    end
)

# (d2) Moshi
@data MEither{L, R} begin
    MLeft(L)
    MRight(R)
end
m_right(::Type{L}, x::R) where {L, R} = MEither.MRight{L, R}(x)
m_left(x::L, ::Type{R}) where {L, R} = MEither.MLeft{L, R}(x)
m_fold(fl, fr, e::MEither.Type) = @match e begin
    MEither.MLeft(x) => fl(x)
    MEither.MRight(x) => fr(x)
end
m_map(f, e::MEither.Type{L, R}) where {L, R} = (
    S = Core.Compiler.return_type(f, Tuple{R});
    @match e begin
        MEither.MLeft(x) => MEither.MLeft{L, S}(x)
        MEither.MRight(x) => MEither.MRight{L, S}(f(x))
    end
)
m_flatmap(f, e::MEither.Type{L, R}) where {L, R} = (
    S = Core.Compiler.return_type(f, Tuple{R});
    @match e begin
        MEither.MLeft(x) => MEither.MLeft{L, rtype(S)}(x)
        MEither.MRight(x) => f(x)::S
    end
)
rtype(::Type{<:MEither.Type{L, R}}) where {L, R} = R

const ENC = [
    ("a tagged struct", a_left, a_right, a_map, a_flatmap, a_fold, nothing),
    ("b bare Union", b_left, b_right, b_map, b_flatmap, b_fold, Union{BLeft{String}, BRight{Int}}),
    ("c abstract", c_left, c_right, c_map, c_flatmap, c_fold, Union{CLeft{String}, CRight{Int}}),
    ("e wrapped Union", w_left, w_right, w_map, w_flatmap, w_fold, nothing),
    ("d1 SumTypes", s_left, s_right, s_map, s_flatmap, s_fold, nothing),
    ("d2 Moshi", m_left, m_right, m_map, m_flatmap, m_fold, nothing),
]

mk(left, right, i, ok) = ok ? right(String, i) : left(MSG, Int)

for (name, left, right, map_, flatmap_, fold_, TV) in ENC
    println("\n=== Either ", name)
    mkt = Base.return_types(mk, Tuple{typeof(left), typeof(right), Int, Bool})[1]
    println("  mk(...) inferred      : ", mkt, "  concrete=", isconcretetype(mkt))
    step(x) = x > 0 ? right(String, x * 2) : left(MSG, Int)
    chain(e) = flatmap_(step, flatmap_(step, flatmap_(step, e)))
    for (lbl, f) in [
            ("map(x->x+1,e)", e -> map_(x -> x + 1, e)), ("3-step flatmap", chain),
            ("fold(length,identity,e)", e -> fold_(length, identity, e)),
        ]
        T = Base.return_types(f, Tuple{mkt})[1]
        println("  ", rpad(lbl, 24), " -> ", T, "  concrete=", isconcretetype(T))
    end
    Random.seed!(1)
    keep = rand(Bool, 10^6)
    v = [mk(left, right, i, keep[i]) for i in 1:(10^6)]
    TV === nothing || (v = convert(Vector{TV}, v))
    E = eltype(v)
    @printf(
        "  Vector{%s} allocatedinline=%s sizeof(elt)=%s summarysize=%.2f MiB\n", E, Base.allocatedinline(E),
        isconcretetype(E) ? string(sizeof(E)) : "n/a", Base.summarysize(v) / 2^20
    )
    sumfold(v) = (
        s = 0; for e in v
            s += fold_(length, identity, e)
        end; s
    )
    sumchain(v) = (
        s = 0; for e in v
            s += fold_(length, identity, chain(e))
        end; s
    )
    sumfold(v); sumchain(v)
    println("  @allocated sumfold = ", @allocated(sumfold(v)), "   sumchain = ", @allocated(sumchain(v)))
    bf = @benchmark $sumfold($v)
    bc = @benchmark $sumchain($v)
    @printf(
        "  median sumfold %.3f ms (allocs %d)   median sumchain %.3f ms (allocs %d)   check %d %d\n",
        median(bf).time / 1.0e6, bf.allocs, median(bc).time / 1.0e6, bc.allocs, sumfold(v), sumchain(v)
    )
end
