"""
    ChuiTypes.Upstream

The one adapter to ChuiCore (ADR-0004). This is the **only** file in `src/` and `ext/` that may
name ChuiCore; a `:quality` test enforces it.

ChuiCore has no registered snapshot yet, so every function below is a local **stand-in**: an
empty generic function that the type files extend with `Upstream.f(...) = ...`. When a ChuiCore
snapshot provides the same name and signature, each stand-in becomes a `using` of ChuiCore's
binding (or a `const` alias of it, for a rename) in this file only (ADR-0004 §3).

Names and conventions mirror ChuiCore ADR-0001 (accepted): Semigroup/Monoid are instance values
(`combine(m, a, b)`, `neutral(m)` fresh on every call); constructor classes are keyed on an owned
tag, and operations with no value to dispatch on take the tag first (`pure(tag, x)`). Names
ChuiCore has not fixed (`chain`, `ap`, `alt`, `zeroalt`, `bimap`) are ChuiTypes proposals
(request R1).

None of these names is exported or public: they may change at the switch-over.
"""
module Upstream

"""
    fmap(f, x)

Functor map (ChuiCore ADR-0001 §3). On every ChuiTypes type it is the same as `Base.map(f, x)`.
"""
function fmap end

"""
    pure(tag, x)

Applicative unit: wraps `x` in the constructor named by `tag` (ChuiCore ADR-0001 §3).
"""
function pure end

"""
    ap(ff, fx)

Applicative apply: applies the function(s) inside `ff` to the value(s) inside `fx`.
Proposal (request R1).
"""
function ap end

"""
    chain(f, x)

Monad bind: `f` maps a value to the same constructor. Proposal (request R1); not `flatmap`,
which `Base.Iterators` owns (ChuiCore ADR-0001 §3).
"""
function chain end

"""
    alt(x, y)

Alternative choice (`<|>`). Proposal (request R1).
"""
function alt end

"""
    zeroalt(tag, T)

Alternative empty value of element type `T` for the constructor named by `tag`. Proposal
(request R1; ChuiCore ADR-0001 §3 names a `zeroalt(tag)`-style operation).
"""
function zeroalt end

"""
    bimap(f, g, x)

Bifunctor map: `f` over the first (left, error, `this`) side, `g` over the second.
Proposal (request R1).
"""
function bimap end

"""
    traverse(tag, f, x)

Traversable traverse: `f` maps each element to the applicative named by `tag`; the result is
that applicative of `x`'s shape (ChuiCore ADR-0001 §3).
"""
function traverse end

"""
    combine(m, a, b)

Semigroup operation of the instance value `m` on its carrier (ChuiCore ADR-0001 §1; the same
binding as the aggregation protocol's `combine(agg, a, b)`).
"""
function combine end

"""
    neutral(m)

Identity of the monoid instance `m`. Returns a fresh value on every call (ChuiCore ADR-0001 §1).
"""
function neutral end

"""
    default_monoid(::Type{T})

The monoid instance used for `T` when none is passed (ChuiCore ADR-0001 §1, closed sugar).
ChuiTypes declares none: `These`' Applicative/Monad need one for their first parameter. Without
a declaration it throws an `ArgumentError` naming `T`.
"""
default_monoid(::Type{T}) where {T} =
    throw(ArgumentError("no default monoid is declared for $T: declare `default_monoid(::Type{$T})`"))

"""
    constructorclass(::Type{T})

Maps a concrete type to its owned constructor tag (ChuiCore ADR-0001 §3).
"""
function constructorclass end

# ---- Transducer stand-ins (ChuiCore ADR-0003; ChuiTypes ADR-0003 §2) ----------------------------
# A minimal placeholder of ChuiCore main's transducer *protocol*: the same names, fields and
# `start`/`next`/`complete` contract, with only the transducers streams use. Not a copy of
# ChuiCore's files (ADR-0004 §2); each binding becomes a `using ChuiCore: …` at the switch-over.

"`Reduced(value)`: a reducing step returns it to stop the fold (ChuiCore's `Reduced`)."
struct Reduced{T}
    value::T
end
"`reduced(x)`: wrap `x` in `Reduced` (an already reduced value is returned as is)."
reduced(x) = Reduced(x)
reduced(x::Reduced) = x
"`unreduced(x)`: the value inside a `Reduced`, or `x`."
unreduced(x) = x
unreduced(x::Reduced) = x.value
"`isreduced(x)`: whether `x` is a `Reduced`."
isreduced(x) = x isa Reduced

"Supertype of the transducers (ChuiCore's `Transducer`): immutable step descriptions."
abstract type Transducer end

"`Map(f)`: send `f(x)` downstream."
struct Map{F} <: Transducer
    f::F
end
"`Filter(p)`: send `x` downstream when `p(x)`."
struct Filter{P} <: Transducer
    p::P
end
"`Take(n)`: the first `n` inputs, then stop."
struct Take <: Transducer
    n::Int
end
"`TakeWhile(p)`: inputs while `p(x)`, then stop."
struct TakeWhile{P} <: Transducer
    p::P
end
"`Scan(op, init)`: send every intermediate accumulator `op(acc, x)` (not `init`)."
struct Scan{F, T} <: Transducer
    op::F
    init::T
end
"`Partition{T}(n)`: vectors of `n` consecutive inputs; the last, shorter one at `complete`."
struct Partition{T} <: Transducer
    n::Int
end
"`Composed(xfs)`: the transducers of the tuple `xfs`, first to last (ChuiCore's `a ⨟ b`)."
struct Composed{T <: Tuple} <: Transducer
    xfs::T
end
_xfs(x::Transducer) = (x,)
_xfs(x::Composed) = x.xfs
"`opcompose(a, b)`: `a`, then `b` (ChuiCore's `⨟` binding; ChuiTypes does not define `⨟`)."
opcompose(a::Transducer, b::Transducer) = Composed((_xfs(a)..., _xfs(b)...))

"`Bottom(op)`: the reducing function of a plain binary `op`."
struct Bottom{F}
    op::F
end
"`R(xf, inner)`: the transducer `xf` in front of the reducing function `inner`."
struct R{X <: Transducer, I}
    xf::X
    inner::I
end
_asrf(op) = Bottom(op)
_asrf(rf::Union{R, Bottom}) = rf
"`asrf(xf, op)`: the reducing function of `xf` in front of `op`."
asrf(xf::Transducer, op) = R(xf, _asrf(op))
asrf(xf::Composed, op) = _apply(xf.xfs, _asrf(op))
_apply(::Tuple{}, rf) = rf
_apply(t::Tuple, rf) = asrf(first(t), _apply(Base.tail(t), rf))

"`start(rf, acc)`: the accumulator a fold begins with; stateful layers wrap their state in it."
start(::Bottom, acc) = acc
start(rf::R, acc) = start(rf.inner, acc)
"`next(rf, acc, x)`: one step; the new accumulator, or a `Reduced` to stop."
next(rf::Bottom, acc, x) = rf.op(acc, x)
"`complete(rf, acc)`: the completion step, run exactly once per fold (also after `Reduced`)."
complete(::Bottom, acc) = acc
complete(rf::R, acc) = complete(rf.inner, acc)

# Per-fold state of a stateful layer, carried in the accumulator: (state, inner accumulator).
struct _State{S, A}
    state::S
    acc::A
end
@inline _rewrap(s, a) = a isa Reduced ? Reduced(_State(s, a.value)) : _State(s, a)

next(rf::R{<:Map}, acc, x) = next(rf.inner, acc, rf.xf.f(x))
next(rf::R{<:Filter}, acc, x) = rf.xf.p(x) ? next(rf.inner, acc, x) : acc
next(rf::R{<:TakeWhile}, acc, x) = rf.xf.p(x) ? next(rf.inner, acc, x) : Reduced(acc)

start(rf::R{Take}, acc) = _State(0, start(rf.inner, acc))
function next(rf::R{Take}, w::_State, x)
    seen = w.state
    seen >= rf.xf.n && return Reduced(w)          # only for Take(0)
    seen += 1
    a = next(rf.inner, w.acc, x)
    a isa Reduced && return Reduced(_State(seen, a.value))
    return seen < rf.xf.n ? _State(seen, a) : Reduced(_State(seen, a))
end
complete(rf::R{Take}, w::_State) = complete(rf.inner, w.acc)

start(rf::R{<:Scan}, acc) = _State(rf.xf.init, start(rf.inner, acc))
function next(rf::R{<:Scan}, w::_State, x)
    s = rf.xf.op(w.state, x)
    return _rewrap(s, next(rf.inner, w.acc, s))
end
complete(rf::R{<:Scan}, w::_State) = complete(rf.inner, w.acc)

function start(rf::R{Partition{T}}, acc) where {T}
    buf = Vector{T}()
    sizehint!(buf, rf.xf.n)
    return _State(buf, start(rf.inner, acc))
end
function next(rf::R{<:Partition}, w::_State, x)
    buf = w.state
    push!(buf, x)
    length(buf) < rf.xf.n && return w
    chunk = copy(buf)
    empty!(buf)
    return _rewrap(buf, next(rf.inner, w.acc, chunk))
end
function complete(rf::R{<:Partition}, w::_State)
    buf = w.state
    a = w.acc
    if !isempty(buf)
        a = unreduced(next(rf.inner, a, copy(buf)))
        empty!(buf)
    end
    return complete(rf.inner, a)
end

end # module Upstream
