# Stream values, the pull protocol, the run driver, simple sources and the run functions
# (ADR-0003 §1, §6–§8, §10; phase-4 spec §2, §8).

"""
    Stream{T}

A **cold**, pull-based, chunked description of a sequence of `T`s (ADR-0003): building one does
nothing; each run (with [`runcollect`](@ref), [`runfold`](@ref), [`runforeach`](@ref),
[`runchunks`](@ref) or [`withbatches`](@ref)) starts it from the beginning and pulls it in
**chunks** (about 1024 elements) that operators process with specialised loops.

Cost, measured 2026-10-20 on Julia 1.13.2 (one thread, loaded machine; ADR-0003 "Measured"):
a fused `map`/`filter` collect costs about 3.8 ns per element (about 5.5× the same Base code on a
`Vector`), `runfold` about 5.3 ns per element (about 43× Base `foldl`), with about 24
allocations (15 KB) per chunk; `merge`/`prefetch`/`mergemap` cost 3.4–7.1 ns per element.
Iterator-level cost is a phase-5 target, not yet met.

`T` is **advisory**, as for [`Effect`](@ref): computed when the value is built, a supertype of
every element, never asserted and never used to convert (`eltype(s)` returns it).

Failures travel as values: a stream ends either normally or with a [`Cause`](@ref) (`Fail`,
`Die` for a thrown exception, `Interrupted`). Every run owns a scope: leaving it, by end, error,
`take` or interruption, stops its fibers and runs its releases (ADR-0003 §7). A user function
that loops without yielding cannot be interrupted until it returns. Cancellation is checked at
every chunk boundary, but a stream of pure chunks never yields to the scheduler: with one
thread, a real-time `timeout` or an `interrupt!` from another task cannot run until the stream
waits on something (a source, a queue, the clock), so bound such a stream with `take`.
"""
struct Stream{T}
    src::Any
end
_stream(::Type{T}, src) where {T} = Stream{T}(src)

Base.eltype(::Type{Stream{T}}) where {T} = T
Base.show(io::IO, ::Stream{T}) where {T} = print(io, "Stream{", T, "}(…)")

"Constructor tag of `Stream` (for `Upstream.pure(StreamTag(), x)`)."
struct StreamTag end

const _CHUNK = 1024

# ---- The protocol ---------------------------------------------------------------------------------
# _open(src, ctx) -> puller; _pull!(p, ctx) -> non-empty AbstractVector | nothing | Cause;
# _close!(p, ctx) -> nothing | Cause, idempotent, run masked. A chunk is never mutated by its
# puller after it is returned.

abstract type _Puller end

# Pull, turning a throw into a cause (`Die`, or `Interrupted` for a `checkcancel`), and checking
# the cancel state first, so pure chunk loops stop at a chunk boundary.
function _spull!(p, ctx::_Ctx)
    _interruptible(ctx) && _iscancelled(ctx.cancel) && return Interrupted()
    try
        return _pull!(p, ctx)
    catch ex
        ex isa InterruptException && rethrow()
        return _classify(ex, catch_backtrace(), 0x00, ctx)
    end
end

struct _FailedP <: _Puller
    cause::Cause
end
_pull!(p::_FailedP, ::_Ctx) = p.cause
_close!(::_FailedP, ::_Ctx) = nothing

function _sopen(src, ctx::_Ctx)
    try
        return _open(src, ctx)
    catch ex
        ex isa InterruptException && rethrow()
        return _FailedP(Die(ex, catch_backtrace()))
    end
end

# Close masked; a throw becomes a `Die`.
function _sclose!(p, ctx::_Ctx)
    mctx = _withmask(ctx, ctx.mask + 1)
    try
        return _close!(p, mctx)
    catch ex
        ex isa InterruptException && rethrow()
        return Die(ex, catch_backtrace())
    end
end

# Combine a run outcome `(ok, value | Cause)` with a close cause.
function _withclose(out::Tuple{Bool, Any}, c)
    c === nothing && return out
    o = out[2]
    return (out[1] || !(o isa Cause)) ? (false, c) : (false, _suppress(o, c))
end

# Run an effect node in the current task under `ctx`, in its own scope (forks it makes are its
# own). Returns the Exit; a ^C is rethrown (the interpreter's PRIM handler records it).
function _runnested(node::_ENode, ctx::_Ctx)
    # The barrier keeps inference from specialising the interpreter on this node's known
    # fields (JET then analyses impossible tags).
    box = Ref{Any}(_ENode(_N_SCOPE, node))
    x, sigint = _interpret(box[]::_ENode, ctx)
    sigint === nothing || throw(sigint)
    return x
end

# The run driver: open, pull every chunk into `consume!` (which may throw), close. `consume!` is
# not specialised on: it stays boxed, so the dynamic call on each (untyped) chunk does not box
# the closure again per chunk.
function _drive(@nospecialize(consume!), src, ctx::_Ctx)
    p = _sopen(src, ctx)
    out = try
        ScopedValues.with(_CTX => ctx) do
            while true
                r = _spull!(p, ctx)
                r === nothing && return (true, nothing)
                r isa Cause && return (false, r)
                try
                    consume!(r)
                catch ex
                    ex isa InterruptException && rethrow()
                    return (false, _classify(ex, catch_backtrace(), 0x00, ctx))
                end
            end
        end
    catch ex
        _sclose!(p, ctx)
        rethrow()
    end
    return _withclose(out, _sclose!(p, ctx))
end

# ---- The widening sink ------------------------------------------------------------------------------
# A chunk under construction: a `Vector{T}` of the advisory `T` while every element `isa T`, else
# a `Vector{Any}` narrowed when emitted (never `convert`, ADR-0002 §1). The chunk so far is the
# first `n` slots of the buffer `v`, where `n` lives in the accumulator `_SinkAcc` that the
# pipeline folds through, so the in-chunk loop keeps it in a register (a count or a `push!`
# through the mutable sink is re-read from memory per element: about 2.5x the cost). An emitted
# vector is never touched again (it belongs to the chunk): `_emit!` starts a fresh buffer of the
# length of the chunk it emitted (so a fused chunk does not regrow); a chunk that fills less
# than a quarter of its buffer is copied out instead and the buffer kept (a sparse `filter`
# hands out no oversized vectors).

mutable struct _Sink{T}
    v::Vector{T}
    wide::Union{Nothing, Vector{Any}}
end
_Sink{T}(cap::Int = 0) where {T} = _Sink{T}(Vector{T}(undef, cap), nothing)

# (One pointer and an `Int`: an accumulator with two pointers is not kept in registers by the
# in-chunk loop, measured about 8x slower through `filter`.)
struct _SinkAcc{T}
    s::_Sink{T}
    n::Int                  # filled slots of `s.v`; -1 once `s.wide` holds the chunk
end
_SinkAcc(s::_Sink{T}) where {T} = _SinkAcc{T}(s, 0)

@inline function _sinkpush(a::_SinkAcc{T}, x) where {T}
    s = a.s
    if a.n >= 0 && x isa T
        n = a.n + 1
        v = s.v
        n > length(v) && _sinkgrow!(v, n)
        @inbounds v[n] = x
        return _SinkAcc{T}(s, n)
    end
    _widenpush!(s, max(a.n, 0), x)
    return _SinkAcc{T}(s, -1)
end
@noinline function _sinkgrow!(v::Vector, n::Int)
    resize!(v, max(2 * length(v), n, 16))      # in place: `v` stays `s.v`
    return nothing
end
@noinline function _widenpush!(s::_Sink, n::Int, x)
    if s.wide === nothing
        w = Vector{Any}(undef, n)
        copyto!(w, 1, s.v, 1, n)
        s.wide = w
    end
    push!(something(s.wide), x)
    return nothing
end
_sinkempty(a::_SinkAcc) = a.n == 0 || (a.n < 0 && isempty(something(a.s.wide)))
# Hand out the chunk; the accumulator continues as `_SinkAcc(a.s)` (empty).
function _emit!(a::_SinkAcc{T}) where {T}
    s = a.s
    if a.n >= 0
        v = s.v
        n = a.n
        4 * n < length(v) && return v[1:n]          # sparse: copy out, keep the buffer
        resize!(v, n)
        s.v = Vector{T}(undef, max(n, 1))
        return v
    end
    w = something(s.wide)
    s.wide = nothing
    return map(identity, w)          # `s.v` was never handed out: it is reused
end
# The chunk of a sink used for exactly one chunk (no replacement buffer).
_take!(a::_SinkAcc) = a.n >= 0 ? resize!(a.s.v, a.n) : map(identity, something(a.s.wide))

# ---- Simple sources -----------------------------------------------------------------------------

include("sources.jl")             # fromiter: the indexed and the generic iteration sources

struct _EmptySrc end
struct _EndP <: _Puller end
_open(::_EmptySrc, ::_Ctx) = _EndP()
_pull!(::_EndP, ::_Ctx) = nothing
_close!(::_EndP, ::_Ctx) = nothing

"`emptystream(T)`: the stream with no elements (advisory element type `T`)."
emptystream(::Type{T}) where {T} = _stream(T, _EmptySrc())

struct _FailSrc
    cause::Cause
end
_open(s::_FailSrc, ::_Ctx) = _FailedP(s.cause)

"`failstream(e)`: the stream that fails at once with `Fail(e)`."
failstream(e) = _stream(Union{}, _FailSrc(Fail(e)))

struct _EffSrc
    node::_ENode
end
mutable struct _EffP <: _Puller
    node::_ENode
    done::Bool
end
_open(s::_EffSrc, ::_Ctx) = _EffP(s.node, false)
function _pull!(p::_EffP, ctx::_Ctx)
    p.done && return nothing
    p.done = true
    x = _runnested(p.node, ctx)
    succeeded(x) || return something(x.c)
    return [x.a]
end
_close!(::_EffP, ::_Ctx) = nothing

"""
    fromeffect(eff::Effect{E,A}) -> Stream{A}

The one-element stream of `eff`'s value; running the stream runs `eff` (once per run). A failure
of `eff` fails the stream with the same cause.
"""
fromeffect(e::Effect{E, A}) where {E, A} = _stream(A, _EffSrc(e.node))

# bracketstream: one element, released when the puller closes.
struct _BracketSrc
    acquire::_ENode
    release::Any
end
mutable struct _BracketP <: _Puller
    s::_BracketSrc
    state::UInt8            # 0 fresh, 1 acquired and emitted, 2 ended, 3 closed
    a::Any
    acquired::Bool
end
_open(s::_BracketSrc, ::_Ctx) = _BracketP(s, 0x00, nothing, false)
function _pull!(p::_BracketP, ctx::_Ctx)
    if p.state == 0x00
        # The whole nested run is masked, scope included: a cancel that arrives during the
        # acquire must not turn an acquired resource into `Interrupted` (it would never be
        # released; found by the :slow stress test).
        x = _runnested(p.s.acquire, _withmask(ctx, ctx.mask + 1))
        succeeded(x) || (p.state = 0x02; return something(x.c))
        p.a = x.a
        p.acquired = true
        p.state = 0x01
        return [x.a]
    end
    p.state = 0x02
    return nothing
end
function _close!(p::_BracketP, ctx::_Ctx)
    p.acquired || return nothing
    p.acquired = false
    ex = _iscancelled(ctx.cancel) ? Failure(Interrupted()) : Success(p.a)
    rel = p.s.release
    node = try
        _nodeof(rel(p.a, ex), "bracketstream's release function")
    catch e
        return Die(e, catch_backtrace())
    end
    x = _runnested(node, ctx)
    return succeeded(x) ? nothing : something(x.c)
end

"""
    bracketstream(acquire::Effect, release) -> Stream

A one-element stream of the value `a` that `acquire` succeeds with (run masked). `release(a, exit)`
(an effect) runs masked, **exactly once**, when that stream's run closes it, whatever ends the
run. `exit` is `Success(a)` when its stream ended normally or the run closed it early, and
`Failure(Interrupted())` when the run was interrupted, or when a concurrent operator stopped a
producer that was still running (for example a `take` after a `merge`). A failing release fails
the run, also behind concurrent operators (or joins a failure's [`suppressed`](@ref) list). Use it with
[`concatmap`](@ref): `concatmap(h -> use(h), bracketstream(open_eff, (h, _) -> close_eff(h)))`.
"""
bracketstream(acquire::Effect{E, A}, release) where {E, A} = _stream(A, _BracketSrc(acquire.node, release))

# ---- Running ------------------------------------------------------------------------------------

_runeffect(::Type{A}, f) where {A} = _eff(Any, A, _ENode(_N_SCOPE, _ENode(_N_PRIM, f)))

mutable struct _Collector{T}
    v::Vector{T}
    wide::Union{Nothing, Vector{Any}}
end
function _collect!(c::_Collector{T}, chunk) where {T}
    if c.wide === nothing && eltype(chunk) <: T
        append!(c.v, chunk)
    else
        if c.wide === nothing
            c.wide = Vector{Any}(c.v)
        end
        append!(something(c.wide), chunk)
    end
    return nothing
end
_result(c::_Collector) = c.wide === nothing ? c.v : map(identity, something(c.wide))

"""
    runcollect(s::Stream) -> Effect{Any,Vector}

The effect that runs `s` and succeeds with its elements in a vector (whose element type is the
tightest of the elements'), or fails as the stream fails.
"""
function runcollect(s::Stream{T}) where {T}
    return _runeffect(
        Vector, ctx -> begin
            c = _Collector{T}(T[], nothing)
            out = _drive(ch -> _collect!(c, ch), s.src, ctx)
            out[1] ? (true, _result(c)) : out
        end
    )
end

"""
    runfold(op, init, s::Stream) -> Effect

The effect that runs `s` and succeeds with `foldl(op, elements; init)`.
"""
function runfold(op, init, s::Stream{T}) where {T}
    return _runeffect(
        Any, ctx -> begin
            f = Ref{Any}(_newfold(op, init, T))
            out = _drive(ch -> _foldstep!(f, ch), s.src, ctx)
            out[1] ? (true, f[].acc) : out
        end
    )
end

# The fold's state. `A` is `typeof(init)` when inference says `op(::A, ::T)` returns exactly that
# concrete type, else `Any`: then a chunk's fold result is stored unboxed (spec D5).
mutable struct _Fold{F, A}
    op::F
    acc::A
end
function _newfold(op::F, init::A, ::Type{T}) where {F, A, T}
    typed = isconcretetype(A) && Base.promote_op(op, A, T) === A
    return typed ? _Fold{F, A}(op, init) : _Fold{F, Any}(op, init)
end
struct _Widened
    acc::Any
end
# One chunk folded into `f.acc` (the one dynamic call per chunk: on the heap `_Fold` and the boxed
# chunk). A result that is not an `A` (inference was too narrow) is handed back, never converted.
function _foldinto!(f::_Fold{F, A}, chunk) where {F, A}
    a = foldl(f.op, chunk; init = f.acc)
    a isa A || return _Widened(a)
    f.acc = a
    return nothing
end
function _foldstep!(f::Base.RefValue{Any}, chunk)
    w = _foldinto!(f[], chunk)
    w === nothing && return nothing
    f[] = _Fold{Any, Any}(f[].op, (w::_Widened).acc)
    return nothing
end

"""
    runforeach(f, s::Stream) -> Effect{Any,Nothing}

The effect that runs `s` and calls the plain function `f(x)` on every element, in order.
"""
runforeach(f, s::Stream) = _runeffect(Nothing, ctx -> _drive(ch -> foreach(f, ch), s.src, ctx))

"""
    runchunks(s::Stream; maxelements = nothing) -> Effect{Any,Vector}

The effect that runs `s` once and succeeds with its chunks, in order: a **snapshot** whose
vectors are fresh and owned by the run (ADR-0008). With `maxelements = n`, a stream with more
than `n` elements fails with `Fail(ArgumentError(…))` after `n + 1` are read; this bounds memory,
not time (use [`timeoutfail`](@ref) for that).
"""
function runchunks(s::Stream; maxelements::Union{Nothing, Integer} = nothing)
    return _runeffect(
        Vector, ctx -> begin
            chunks = Any[]
            n = Ref(0)
            over = Ref(false)
            out = _drive(s.src, ctx) do ch
                n[] += length(ch)
                if maxelements !== nothing && n[] > maxelements
                    over[] = true
                    throw(_Overflow())
                end
                push!(chunks, ch)
            end
            if over[]
                return (false, Fail(ArgumentError("the stream has more than maxelements = $maxelements elements")))
            end
            out[1] ? (true, map(identity, chunks)) : out
        end
    )
end
struct _Overflow <: Exception end

# ---- withbatches ----------------------------------------------------------------------------------

mutable struct _Batches
    p::Any
    ctx::_Ctx
    valid::Bool
    done::Bool
end
Base.IteratorSize(::Type{_Batches}) = Base.SizeUnknown()
Base.eltype(::Type{_Batches}) = AbstractVector
function Base.iterate(b::_Batches, _ = nothing)
    b.valid || throw(ArgumentError("a withbatches handle is valid only inside its function"))
    b.done && return nothing
    r = _spull!(b.p, b.ctx)
    if r === nothing
        b.done = true
        return nothing
    elseif r isa Cause
        b.done = true
        throw(_exception(r))
    end
    return (r, nothing)
end

"""
    withbatches(f, s::Stream)

Run `s` and call `f(it)`, where `it` iterates the chunks in order (`Base.SizeUnknown()`), and
return `f`'s value. A stream failure throws from `iterate` as [`run`](@ref) throws (the original
exception). `it` is valid only inside `f`; leaving `f`, normally or by a throw, closes the run.
This is a plain blocking call, like `run` (nested under an enclosing `sync`'s fiber, if any).
"""
function withbatches(f, s::Stream)
    eff = _runeffect(
        Any, ctx -> begin
            p = _sopen(s.src, ctx)
            b = _Batches(p, ctx, true, false)
            v = try
                ScopedValues.with(() -> f(b), _CTX => ctx)
            catch
                b.valid = false
                _sclose!(p, ctx)
                rethrow()
            end
            b.valid = false
            _withclose((true, v), _sclose!(p, ctx))
        end
    )
    return run(eff)
end

# ---- Typeclass stand-ins (ADR-0004; rule N5 at the switch-over, spec §12) -------------------------

Upstream.fmap(f, s::Stream) = map(f, s)
Upstream.pure(::StreamTag, x) = fromiter([x])
Upstream.ap(ff::Stream, fx::Stream) = concatmap(f -> map(f, fx), ff)
Upstream.chain(k, s::Stream) = concatmap(k, s)
Upstream.constructorclass(::Type{<:Stream}) = StreamTag()
