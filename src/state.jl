# State{S}: a computation that reads and replaces a state of the declared type S (ADR-0007).

"""
    State{S}

A computation that threads a state of type `S` and gives a value. Build one with
[`getstate`](@ref), [`putstate`](@ref), [`modifystate`](@ref),
`Upstream.pure(StateTag{S}(), x)`, `map` and [`andthen`](@ref); run it with
[`runstate`](@ref).

`S` is declared by the caller and the run keeps the state an `S`, so
`runstate(::State{Int}, ::Int)` is inferred as `Tuple{Any,Int}`; the result type is not a
parameter (ADR-0007 §1): assert one with `runstate(m, s0, T)`. Values are immutable erased
programs, stack-safe at any bind depth; there is no `==`.

# Examples
```jldoctest
julia> incr = andthen(s -> putstate(s + 1), getstate(Int));

julia> runstate(andthen(_ -> getstate(Int), incr), 1)
(2, 2)
```
"""
struct State{S}
    node::_RNode
    State{S}(::_New, node::_RNode) where {S} = new{S}(node)
end

"""
    StateTag{S}

Constructor tag of `State{S}`: `Upstream.pure(StateTag{S}(), x)` gives `x` and leaves the
state unchanged.
"""
struct StateTag{S} end

"""
    getstate(S) -> State{S}

The computation that gives the current state, of the declared type `S`.
"""
getstate(::Type{S}) where {S} = State{S}(_NEW, _RNode(_R_GET, nothing, nothing))

"""
    putstate(S, x) -> State{S}
    putstate(x) -> State{typeof(x)}

The computation that replaces the state by `x` and gives `nothing`. `putstate(S, x)` stores
`convert(S, x)` when the value is built, so an `x` that does not convert throws there.
"""
putstate(::Type{S}, x) where {S} = State{S}(_NEW, _RNode(_R_PUT, convert(S, x), nothing))
putstate(x) = putstate(typeof(x), x)

"""
    modifystate(f, S) -> State{S}

The computation that replaces the state `s` by `f(s)` (converted to `S`) and gives `nothing`.
"""
modifystate(f, ::Type{S}) where {S} = State{S}(_NEW, _RNode(_R_MODIFY, nothing, f))

"""
    runstate(m::State{S}, s0[, T]) -> (a, s::S)

Runs `m` from the state `s0` (converted to `S`) and returns its value and the final state.
With `T`, the value is asserted to be a `T`. A continuation that returns anything but a
`State{S}` (for example a `State{UInt8}` inside a `State{Int}`) makes the run throw an
`ArgumentError` naming both types.
"""
function runstate(m::State{S}, s0) where {S}
    a, s, _ = _rwsrun(m.node, State{S}, Nothing, S, Nothing, nothing, s0, _NoMonoid(), nothing)
    return (a, s)
end
function runstate(m::State, s0, ::Type{T}) where {T}
    a, s = runstate(m, s0)
    return (a::T, s)
end

Base.map(f, m::State{S}) where {S} = State{S}(_NEW, _mapnode(f, m.node))
Upstream.fmap(f, m::State) = map(f, m)
Upstream.pure(::StateTag{S}, x) where {S} = State{S}(_NEW, _purenode(x))
Upstream.ap(ff::State{S}, fx::State{S}) where {S} = State{S}(_NEW, _apnode(State{S}, ff, fx))
Upstream.chain(k, m::State{S}) where {S} = State{S}(_NEW, _bindnode(k, m.node))
andthen(k, m::State) = Upstream.chain(k, m)
Upstream.constructorclass(::Type{State{S}}) where {S} = StateTag{S}()

Base.show(io::IO, ::State{S}) where {S} = print(io, "State{", S, "}(…)")
