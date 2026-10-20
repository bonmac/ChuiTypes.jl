# Reader{R}: a computation that reads an environment of the declared type R (ADR-0007).

"""
    Reader{R}

A computation that reads an environment of type `R` and gives a value. Build one with
[`ask`](@ref), [`asks`](@ref), `Upstream.pure(ReaderTag{R}(), x)`, `map` and
[`andthen`](@ref); run it with [`runreader`](@ref). [`withreader`](@ref) runs a part of it in
a changed environment.

`R` is declared by the caller; the result type is not a parameter (ADR-0007 §1), so a run
gives `Any` unless a type is asserted with `runreader(m, r, T)`. A value is an immutable,
erased program: binds are data, run by an explicit-stack loop, so chains of any depth are
stack-safe. There is no `==`: two readers are equal only if they agree on every environment.

# Examples
```jldoctest
julia> m = andthen(x -> asks(r -> x + r, Int), ask(Int));

julia> runreader(m, 2)
4

julia> runreader(withreader(r -> 10r, ask(Int)), 2, Int)
20
```
"""
struct Reader{R}
    node::_RNode
    Reader{R}(::_New, node::_RNode) where {R} = new{R}(node)
end

"""
    ReaderTag{R}

Constructor tag of `Reader{R}`: `Upstream.pure(ReaderTag{R}(), x)` is the reader that ignores
its environment and gives `x`.
"""
struct ReaderTag{R} end

"""
    ask(R) -> Reader{R}

The reader that gives its environment, of the declared type `R`.
"""
ask(::Type{R}) where {R} = Reader{R}(_NEW, _RNode(_R_ASK, nothing, nothing))

"""
    asks(f, R) -> Reader{R}

The reader that gives `f(r)` for its environment `r::R`; the same as `map(f, ask(R))`.
"""
asks(f, ::Type{R}) where {R} = Reader{R}(_NEW, _mapnode(f, ask(R).node))

"""
    withreader(f, m::Reader{R}) -> Reader{R}

Runs `m` in the environment `f(r)` (converted to `R`), then restores `r` for what follows
(Reader's `local`). Nesting is stack-safe: the restore is a frame on the run's stack.
"""
withreader(f, m::Reader{R}) where {R} = Reader{R}(_NEW, _RNode(_R_LOCAL, m.node, f))

"""
    runreader(m::Reader{R}, r[, T])

Runs `m` in the environment `r` (converted to `R`) and returns its value. With `T`, the value
is asserted to be a `T` (a `TypeError` otherwise), so the result is inferred as `T`. A
continuation that returns anything but a `Reader{R}` makes the run throw an `ArgumentError`
naming both types.
"""
runreader(m::Reader{R}, r) where {R} =
    first(_rwsrun(m.node, Reader{R}, R, Nothing, Nothing, r, nothing, _NoMonoid(), nothing))
runreader(m::Reader, r, ::Type{T}) where {T} = runreader(m, r)::T

Base.map(f, m::Reader{R}) where {R} = Reader{R}(_NEW, _mapnode(f, m.node))
Upstream.fmap(f, m::Reader) = map(f, m)
Upstream.pure(::ReaderTag{R}, x) where {R} = Reader{R}(_NEW, _purenode(x))
Upstream.ap(ff::Reader{R}, fx::Reader{R}) where {R} = Reader{R}(_NEW, _apnode(Reader{R}, ff, fx))
Upstream.chain(k, m::Reader{R}) where {R} = Reader{R}(_NEW, _bindnode(k, m.node))
andthen(k, m::Reader) = Upstream.chain(k, m)
Upstream.constructorclass(::Type{Reader{R}}) where {R} = ReaderTag{R}()

Base.show(io::IO, ::Reader{R}) where {R} = print(io, "Reader{", R, "}(…)")
