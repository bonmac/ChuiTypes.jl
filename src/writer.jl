# Writer{W}: a computation that appends to a log of the declared type W (ADR-0007).

"""
    Writer{W}

A computation that gives a value and writes log entries of type `W`. Build one with
[`tell`](@ref), `Upstream.pure(WriterTag{W}(), x)`, `map` and [`andthen`](@ref); run it with
[`runwriter`](@ref), which takes the monoid instance that combines the entries (there is no
default monoid). [`listening`](@ref) and [`censor`](@ref) observe and rewrite a part's log.

The run starts from `Upstream.neutral(mon)` once and threads one accumulator,
`acc = Upstream.combine(mon, acc, w)` for each `tell(w)`, in execution order, so left- and
right-nested chains give the same log. **The cost is the monoid's:** a monoid that combines
into its first argument in place (for example `append!` into the accumulator, which the run
owns) costs linear time in the number of entries; a copying one (`vcat`) copies the log on
every `tell`, which is quadratic in total (ADR-0007: about 27 ns versus 987 ns per `tell` at
10^4 entries). The entries passed to `tell` are never mutated: they are always the second
argument of `combine`.

The result type is not a parameter: assert one with `runwriter(m, mon, T)`. Values are
immutable erased programs, stack-safe at any bind depth; there is no `==`.

# Examples
```jldoctest
julia> struct Cat end

julia> ChuiTypes.Upstream.combine(::Cat, a::String, b::String) = a * b;

julia> ChuiTypes.Upstream.neutral(::Cat) = "";

julia> runwriter(andthen(_ -> tell("b"), tell("a")), Cat())
(nothing, "ab")
```
"""
struct Writer{W}
    node::_RNode
    Writer{W}(::_New, node::_RNode) where {W} = new{W}(node)
end

"""
    WriterTag{W}

Constructor tag of `Writer{W}`: `Upstream.pure(WriterTag{W}(), x)` gives `x` and writes
nothing.
"""
struct WriterTag{W} end

"""
    tell(w) -> Writer{typeof(w)}
    tell(W, w) -> Writer{W}

The writer that appends the entry `w` (converted to `W`, when given) to the log and gives
`nothing`.
"""
tell(w) = Writer{typeof(w)}(_NEW, _RNode(_R_TELL, w, nothing))
tell(::Type{W}, w) where {W} = Writer{W}(_NEW, _RNode(_R_TELL, convert(W, w), nothing))

"""
    listening(m::Writer{W}) -> Writer{W}

Runs `m` and gives `(a, w)`: `m`'s value and the log `m` wrote (starting from a fresh
`neutral(mon)`). The log is also kept in the outer log. Nesting is stack-safe.
"""
listening(m::Writer{W}) where {W} = Writer{W}(_NEW, _RNode(_R_LISTEN, m.node, nothing))

"""
    censor(f, m::Writer{W}) -> Writer{W}

Runs `m`, then replaces the log `m` wrote by `f(log)` before it joins the outer log; gives
`m`'s value. Nesting is stack-safe.
"""
censor(f, m::Writer{W}) where {W} = Writer{W}(_NEW, _RNode(_R_CENSOR, m.node, f))

"""
    runwriter(m::Writer{W}, mon[, T]) -> (a, w::W)

Runs `m` with the monoid instance `mon` and returns its value and its log. The log starts
from `Upstream.neutral(mon)`, called once per run (and once per `listening`/`censor` scope),
and grows by `acc = Upstream.combine(mon, acc, w)` per `tell(w)` in execution order. With `T`,
the value is asserted to be a `T`. A continuation that returns anything but a `Writer{W}`
makes the run throw an `ArgumentError` naming both types.
"""
function runwriter(m::Writer{W}, mon) where {W}
    a, _, w = _rwsrun(m.node, Writer{W}, Nothing, Nothing, W, nothing, nothing, mon, Upstream.neutral(mon))
    return (a, w)
end
function runwriter(m::Writer, mon, ::Type{T}) where {T}
    a, w = runwriter(m, mon)
    return (a::T, w)
end

Base.map(f, m::Writer{W}) where {W} = Writer{W}(_NEW, _mapnode(f, m.node))
Upstream.fmap(f, m::Writer) = map(f, m)
Upstream.pure(::WriterTag{W}, x) where {W} = Writer{W}(_NEW, _purenode(x))
Upstream.ap(ff::Writer{W}, fx::Writer{W}) where {W} = Writer{W}(_NEW, _apnode(Writer{W}, ff, fx))
Upstream.chain(k, m::Writer{W}) where {W} = Writer{W}(_NEW, _bindnode(k, m.node))
andthen(k, m::Writer) = Upstream.chain(k, m)
Upstream.constructorclass(::Type{Writer{W}}) where {W} = WriterTag{W}()

Base.show(io::IO, ::Writer{W}) where {W} = print(io, "Writer{", W, "}(…)")
