# Option encodings: inference, allocation, layout, benchmark.
# Run: julia +release --startup-file=no --project=env113 option_bench.jl
#      julia +lts     --startup-file=no --project=env110 option_bench.jl
using BenchmarkTools, Random, Printf
using SumTypes
using Moshi.Data: @data
using Moshi.Match: @match
import ErrorTypes

println("julia ", VERSION)
BenchmarkTools.DEFAULT_PARAMETERS.seconds = 2

# ---------------- (a) tagged concrete struct ----------------
struct TOpt{T}
    isset::Bool
    value::T                       # left undefined when empty
    TOpt{T}() where {T} = new{T}(false)
    TOpt{T}(x) where {T} = new{T}(true, x)
end
a_some(x::T) where {T} = TOpt{T}(x)
a_none(::Type{T}) where {T} = TOpt{T}()
a_map(f, o::TOpt{T}) where {T} = (R = Core.Compiler.return_type(f, Tuple{T}); o.isset ? TOpt{R}(f(o.value)) : TOpt{R}())
a_flatmap(f, o::TOpt{T}) where {T} = (R = Core.Compiler.return_type(f, Tuple{T}); o.isset ? f(o.value)::R : R())
a_fold(z, f, o::TOpt) = o.isset ? f(o.value) : z

# ---------------- (b) bare small union of two concrete structs ----------------
struct BNone end
struct BSome{T}
    value::T
end
const BOpt{T} = Union{BNone, BSome{T}}
b_some(x) = BSome(x)
b_none(::Type{T}) where {T} = BNone()
b_map(f, ::BNone) = BNone()
b_map(f, o::BSome) = BSome(f(o.value))
b_flatmap(f, ::BNone) = BNone()
b_flatmap(f, o::BSome) = f(o.value)
b_fold(z, f, ::BNone) = z
b_fold(z, f, o::BSome) = f(o.value)

# ---------------- (c) abstract supertype ----------------
abstract type COpt{T} end
struct CNone <: COpt{Union{}} end
struct CSome{T} <: COpt{T}
    value::T
end
c_some(x) = CSome(x)
c_none(::Type{T}) where {T} = CNone()
c_map(f, ::CNone) = CNone()
c_map(f, o::CSome) = CSome(f(o.value))
c_flatmap(f, ::CNone) = CNone()
c_flatmap(f, o::CSome) = f(o.value)
c_fold(z, f, ::CNone) = z
c_fold(z, f, o::CSome) = f(o.value)

# ---------------- (e) wrapped union: concrete struct around a small Union field ----------------
struct WNone end
struct WSome{T}
    value::T
end
struct WOpt{T}
    x::Union{WNone, WSome{T}}
end
w_some(x::T) where {T} = WOpt{T}(WSome(x))
w_none(::Type{T}) where {T} = WOpt{T}(WNone())
function w_map(f, o::WOpt{T}) where {T}
    R = Core.Compiler.return_type(f, Tuple{T})
    x = o.x
    return x isa WSome ? WOpt{R}(WSome{R}(f(x.value))) : WOpt{R}(WNone())
end
function w_flatmap(f, o::WOpt{T}) where {T}
    R = Core.Compiler.return_type(f, Tuple{T})   # R is WOpt{U}
    x = o.x
    return x isa WSome ? f(x.value)::R : R(WNone())
end
w_fold(z, f, o::WOpt) = (x = o.x; x isa WSome ? f(x.value) : z)

# ---------------- (d1) SumTypes.jl ----------------
@sum_type SOpt{T} :hidden begin
    SNone
    SSome{T}(::T)
end
s_some(x::T) where {T} = SOpt{T}(SOpt'.SSome(x))
s_none(::Type{T}) where {T} = SOpt{T}(SOpt'.SNone)
s_fold(z, f, o::SOpt) = @cases o begin
    SNone => z
    SSome(x) => f(x)
end
function s_map(f, o::SOpt{T}) where {T}
    R = Core.Compiler.return_type(f, Tuple{T})
    return @cases o begin
        SNone => SOpt{R}(SOpt'.SNone)
        SSome(x) => SOpt{R}(SOpt'.SSome(f(x)))
    end
end
function s_flatmap(f, o::SOpt{T}) where {T}
    R = Core.Compiler.return_type(f, Tuple{T})
    return @cases o begin
        SNone => R(SOpt'.SNone)
        SSome(x) => f(x)::R
    end
end

# ---------------- (d2) Moshi.jl ----------------
@data MOpt{T} begin
    MSome(T)
    MNone()
end
m_some(x::T) where {T} = MOpt.MSome{T}(x)
m_none(::Type{T}) where {T} = MOpt.MNone{T}()
m_fold(z, f, o::MOpt.Type) = @match o begin
    MOpt.MNone() => z
    MOpt.MSome(x) => f(x)
end
function m_map(f, o::MOpt.Type{T}) where {T}
    R = Core.Compiler.return_type(f, Tuple{T})
    return @match o begin
        MOpt.MNone() => MOpt.MNone{R}()
        MOpt.MSome(x) => MOpt.MSome{R}(f(x))
    end
end
function m_flatmap(f, o::MOpt.Type{T}) where {T}
    R = Core.Compiler.return_type(f, Tuple{T})
    return @match o begin
        MOpt.MNone() => MOpt.MNone{eltype_(R)}()
        MOpt.MSome(x) => f(x)::R
    end
end
eltype_(::Type{MOpt.Type{T}}) where {T} = T

# ---------------- (f) ErrorTypes.jl Option (wrapped union, library) ----------------
e_some(x::T) where {T} = ErrorTypes.Option{T}(ErrorTypes.some(x))
e_none(::Type{T}) where {T} = ErrorTypes.none(T)
e_fold(z, f, o) = ErrorTypes.map_or(f, o, z)
e_map(f, o::ErrorTypes.Option{T}) where {T} = ErrorTypes.and_then(f, Core.Compiler.return_type(f, Tuple{T}), o)
e_flatmap(f, o::ErrorTypes.Option{T}) where {T} =
    (R = Core.Compiler.return_type(f, Tuple{T}); ErrorTypes.is_error(o) ? R(ErrorTypes.none) : f(ErrorTypes.unwrap(o))::R)

# typed-vector variants of (b) and (c): the best case for those encodings
const TYPEDVEC = Dict("b bare Union" => Union{BNone, BSome{Int}}, "c abstract" => Union{CNone, CSome{Int}})

const ENC = [
    ("a tagged struct", a_some, a_none, a_map, a_flatmap, a_fold),
    ("b bare Union", b_some, b_none, b_map, b_flatmap, b_fold),
    ("c abstract", c_some, c_none, c_map, c_flatmap, c_fold),
    ("e wrapped Union", w_some, w_none, w_map, w_flatmap, w_fold),
    ("d1 SumTypes", s_some, s_none, s_map, s_flatmap, s_fold),
    ("d2 Moshi", m_some, m_none, m_map, m_flatmap, m_fold),
    ("f ErrorTypes", e_some, e_none, e_map, e_flatmap, e_fold),
]

rt(f, args...) = Base.return_types(f, map(typeof, args))[1]

# options built by a runtime-dependent branch: the realistic case
mk(some, none, i, keep) = keep ? some(i) : none(Int)

for (name, some, none, map_, flatmap_, fold_) in ENC
    println("\n=== ", name)
    o = mk(some, none, 3, rand(Bool))
    mkt = Base.return_types(mk, Tuple{typeof(some), typeof(none), Int, Bool})[1]
    println("  mk(...) inferred      : ", mkt, "  concrete=", isconcretetype(mkt))
    step(x) = x > 0 ? some(x * 2) : none(Int)
    chain(o) = flatmap_(step, flatmap_(step, flatmap_(step, o)))
    for (lbl, f, args) in [
            ("map(x->x+1,o)", (o -> map_(x -> x + 1, o)), (o,)),
            ("3-step flatmap", chain, (o,)),
            ("fold(0,identity,o)", (o -> fold_(0, identity, o)), (o,)),
        ]
        # infer from the declared input type mkt (what a caller sees)
        T = Base.return_types(f, Tuple{mkt})[1]
        println("  ", rpad(lbl, 22), " -> ", T, "  concrete=", isconcretetype(T))
    end
    # layout of a vector of 10^6 options, ~50% empty
    Random.seed!(1)
    keep = rand(Bool, 10^6)
    v = [mk(some, none, i, keep[i]) for i in 1:(10^6)]
    E = eltype(v)
    @printf(
        "  Vector eltype %s  isbitstype=%s  allocatedinline=%s  sizeof(elt)=%s  summarysize=%.2f MiB\n",
        E, isbitstype(E), Base.allocatedinline(E), isconcretetype(E) ? string(sizeof(E)) : "n/a", Base.summarysize(v) / 2^20
    )
    sumfold(v) = (
        s = 0; for o in v
            s += fold_(0, identity, o)
        end; s
    )
    sumchain(v) = (
        s = 0; for o in v
            s += fold_(0, identity, chain(o))
        end; s
    )
    sumfold(v); sumchain(v)
    println("  @allocated sumfold   = ", @allocated(sumfold(v)), "   sumchain = ", @allocated(sumchain(v)))
    bf = @benchmark $sumfold($v)
    bc = @benchmark $sumchain($v)
    @printf(
        "  median sumfold %.3f ms (allocs %d)   median sumchain %.3f ms (allocs %d)\n",
        median(bf).time / 1.0e6, bf.allocs, median(bc).time / 1.0e6, bc.allocs
    )
    println("  check: ", sumfold(v), " ", sumchain(v))
    if haskey(TYPEDVEC, name)
        tv = convert(Vector{TYPEDVEC[name]}, v)
        U = eltype(tv)
        @printf("  TYPED Vector{%s}  allocatedinline=%s  summarysize=%.2f MiB\n", U, Base.allocatedinline(U), Base.summarysize(tv) / 2^20)
        sumfold(tv); sumchain(tv)
        println("  TYPED @allocated sumfold = ", @allocated(sumfold(tv)), "   sumchain = ", @allocated(sumchain(tv)))
        bf = @benchmark $sumfold($tv)
        bc = @benchmark $sumchain($tv)
        @printf(
            "  TYPED median sumfold %.3f ms (allocs %d)   median sumchain %.3f ms (allocs %d)\n",
            median(bf).time / 1.0e6, bf.allocs, median(bc).time / 1.0e6, bc.allocs
        )
    end
    # String payload: non-isbits T
    sv = [keep[i] ? some(string(i)) : none(String) for i in 1:(10^6)]
    if haskey(TYPEDVEC, name)
        sv = convert(Vector{name[1] == 'b' ? Union{BNone, BSome{String}} : Union{CNone, CSome{String}}}, sv)
    end
    SE = eltype(sv)
    sumlen(v) = (
        s = 0; for o in v
            s += fold_(0, length, o)
        end; s
    )
    sumlen(sv)
    bs = @benchmark $sumlen($sv)
    @printf(
        "  STRING Vector{%s} allocatedinline=%s summarysize=%.2f MiB  @allocated=%d  median %.3f ms\n",
        SE, Base.allocatedinline(SE), Base.summarysize(sv) / 2^20, @allocated(sumlen(sv)), median(bs).time / 1.0e6
    )
end

println("\n=== storage of generated types")
for T in (TOpt{Int}, WOpt{Int}, SOpt{Int}, MOpt.Type{Int}, TOpt{String}, WOpt{String}, SOpt{String}, MOpt.Type{String})
    println("  ", rpad(string(T), 22), " fields=", fieldnames(T), " types=", fieldtypes(T), " isbits=", isbitstype(T), " inline=", Base.allocatedinline(T), " sizeof=", sizeof(T))
end
