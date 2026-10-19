# Constructors without a value type, Validation accumulation, NonEmpty, State/Reader, LazyList.
using BenchmarkTools, Printf
println("julia ", VERSION)
BenchmarkTools.DEFAULT_PARAMETERS.seconds = 2
rt(f, T...) = Base.return_types(f, Tuple{T...})[1]

# ---- 1. typed empty constructors (wrapped-union Option) ----
struct WNone end
struct WSome{T}
    value::T
end
struct Opt{T}
    x::Union{WNone, WSome{T}}
end
Opt{T}() where {T} = Opt{T}(WNone())          # none(Int) / Opt{Int}()
none(::Type{T}) where {T} = Opt{T}()
some(x::T) where {T} = Opt{T}(WSome(x))
# untyped singleton none, converted at the use site
struct NoneT end
const NONE = NoneT()
Base.convert(::Type{Opt{T}}, ::NoneT) where {T} = Opt{T}()
f_untyped(x::Int)::Opt{Int} = x > 0 ? some(x) : NONE      # return-type annotation converts
f_typed(x::Int) = x > 0 ? some(x) : none(Int)
f_bad(x::Int) = x > 0 ? some(x) : NONE                     # no annotation: Union
println("\n[ctor] f_typed   -> ", rt(f_typed, Int))
println("[ctor] f_untyped -> ", rt(f_untyped, Int), " (::Opt{Int} annotation + convert)")
println("[ctor] f_bad     -> ", rt(f_bad, Int))
println("[ctor] Opt{Int}() isbits-inline=", Base.allocatedinline(Opt{Int}), " sizeof=", sizeof(Opt{Int}))

# ---- 2. Validation: errors as Vector{E} vs as a growing tuple ----
struct Invalid{E}
    errs::Vector{E}
end
struct Valid{A}
    value::A
end
struct Validation{E, A}
    x::Union{Invalid{E}, Valid{A}}
end
valid(::Type{E}, a::A) where {E, A} = Validation{E, A}(Valid(a))
invalid(e::E, ::Type{A}) where {E, A} = Validation{E, A}(Invalid([e]))
# applicative zip: accumulate both sides' errors
function vzip(a::Validation{E, A}, b::Validation{E, B}) where {E, A, B}
    xa, xb = a.x, b.x
    if xa isa Valid && xb isa Valid
        return Validation{E, Tuple{A, B}}(Valid((xa.value, xb.value)))
    end
    errs = E[]
    xa isa Invalid && append!(errs, xa.errs)
    xb isa Invalid && append!(errs, xb.errs)
    return Validation{E, Tuple{A, B}}(Invalid(errs))
end
check_pos(x::Int) = x > 0 ? valid(String, x) : invalid("not positive", Int)
check_even(x::Int) = iseven(x) ? valid(String, x) : invalid("odd", Int)
both(x) = vzip(check_pos(x), check_even(x))
println("\n[valid] both(x) -> ", rt(both, Int), " concrete=", isconcretetype(rt(both, Int)))
println("[valid] Validation{String,Int} sizeof=", sizeof(Validation{String, Int}), " allocatedinline=", Base.allocatedinline(Validation{String, Int}))
both(2); both(-3)
println("[valid] @allocated both(2) (valid,valid)    = ", @allocated(both(2)))
println("[valid] @allocated both(-3) (invalid,invalid)= ", @allocated(both(-3)))
# tuple-of-errors accumulation: the type grows with the number of errors
tz(a::Tuple, b::Tuple) = (a..., b...)
errs_tuple(x) = tz(x > 0 ? () : ("not positive",), iseven(x) ? () : ("odd",))
println("[valid] tuple accumulation errs_tuple(x) -> ", rt(errs_tuple, Int))

# ---- 3. NonEmpty: head + Vector tail ----
struct NonEmpty{T}
    head::T; tail::Vector{T}
end
nemap(f, n::NonEmpty{T}) where {T} = NonEmpty(f(n.head), map(f, n.tail))
println("\n[nonempty] map -> ", rt(n -> nemap(x -> x + 1, n), NonEmpty{Int}), "  first(n) -> ", rt(n -> n.head, NonEmpty{Int}))

# ---- 4. State / Reader as a struct over the function type ----
struct State{F}
    run::F
end                     # run: s -> (a, s')
st_pure(a) = State(s -> (a, s))
st_flatmap(f, m::State) = State(s -> ((a, s2) = m.run(s); f(a).run(s2)))
const incr = State(s -> (s, s + 1))      # const: a non-const global captured in a lambda infers Any
const prog = st_flatmap(a -> st_flatmap(b -> st_flatmap(c -> st_pure(a + b + c), incr), incr), incr)
println("\n[state] typeof(prog) concrete=", isconcretetype(typeof(prog)), "  run(0) -> ", rt(s -> prog.run(s), Int), " = ", prog.run(0))
runp(p, s) = p.run(s)
runp(prog, 0)
println("[state] @allocated prog.run(0) = ", @allocated(runp(prog, 0)))
struct StateAny
    run::Function
end               # erased function type
st2_flatmap(f, m::StateAny) = StateAny(s -> ((a, s2) = m.run(s); f(a).run(s2)))
const incr2 = StateAny(s -> (s, s + 1))
const prog2 = st2_flatmap(a -> st2_flatmap(b -> StateAny(s -> (a + b, s)), incr2), incr2)
println("[state] StateAny (run::Function) run(0) -> ", rt(s -> prog2.run(s), Int))
runp(prog2, 0)
println("[state] @allocated StateAny run(0) = ", @allocated(runp(prog2, 0)))

# ---- 5. LazyList: cons cell with a thunk ----
struct LNil end
struct LCons{T, F}
    head::T; tail::F
end      # tail: () -> LazyList
# a generic lazy list must erase the thunk type, otherwise each cell has a new type
struct Lazy{T}
    cell::Union{LNil, Tuple{T, Function}}
end
lrange(a, b) = a > b ? Lazy{Int}(LNil()) : Lazy{Int}((a, () -> lrange(a + 1, b)))
function lsum(l::Lazy{T}) where {T}
    s = zero(T)
    c = l.cell
    while c isa Tuple
        s += c[1]
        c = (c[2]()::Lazy{T}).cell
    end
    return s
end
println("\n[lazy] lsum -> ", rt(lsum, Lazy{Int}))
l = lrange(1, 10_000); lsum(l)
println("[lazy] @allocated lsum(lrange(1,10^4)) = ", @allocated(lsum(l)), "  (each forced tail builds a closure + cell)")
b = @benchmark lsum($l)
@printf("[lazy] median lsum %.3f us vs sum(1:10^4) on a Vector %.3f us\n", median(b).time / 1.0e3, median(@benchmark sum($(collect(1:10_000)))).time / 1.0e3)
