# Effect values, causes and exits (ADR-0002 §1, §3; spec §3).

# ---- Nodes ----------------------------------------------------------------------------------
# One concrete node struct with a tag and untyped payloads (the layout ADR-0007 measured as B2).
# The interpreter (interpreter.jl) dispatches on the tag.

const _N_PURE = 0x01        # a: value
const _N_FAIL = 0x02        # a: Cause
const _N_SYNC = 0x03        # a: f, b: 0x00 sync (throw = Die) / 0x01 attempt (throw = Fail)
const _N_DEFER = 0x04       # a: f returning an Effect
const _N_MAP = 0x05         # a: inner node, b: f
const _N_BIND = 0x06        # a: inner node, b: k returning an Effect
const _N_CATCH = 0x07       # a: inner node, b: handler, c: 0x01 Fail only / 0x02 Fail and Die
const _N_PROVIDE = 0x08     # a: inner node, b: Vector{Any} of services
const _N_SERVICE = 0x09     # a: the requested type
const _N_MASK = 0x0a        # a: inner node (uninterruptible)
const _N_IMASK = 0x0b       # a: f(restore) returning an Effect
const _N_SETMASK = 0x0c     # a: inner node, b: mask depth to run it at (restore)
const _N_SCOPE = 0x0d       # a: inner node
const _N_PRIM = 0x0e        # a: f(ctx) -> (ok::Bool, value or Cause); a blocking runtime primitive
const _N_BRACKET = 0x0f     # a: acquire node, b: use(a), c: release(a, exit)
const _N_ACQREL = 0x10      # a: acquire node, b: release(a, exit), registered on the scope
const _N_CTX = 0x11         # a: f(ctx) returning an Effect

struct _ENode
    tag::UInt8
    a::Any
    b::Any
    c::Any
end
_ENode(tag::UInt8, a = nothing, b = nothing) = _ENode(tag, a, b, nothing)

"""
    Effect{E,A}

A description of a computation that may fail with an error of type `E` or succeed with a
value of type `A`, interpreted by the runtime when it is run ([`run`](@ref), [`runexit`](@ref),
[`start`](@ref)). Effects are values: building one does nothing, and running one twice runs it
twice.

`E` and `A` are **advisory**: they are computed when the value is built (with
`Base.promote_op`, ADR-0001 §4) and are never asserted, so they may be wider than the real
outcome. `run(eff, T)` asserts a type you declare instead.

The environment is not a type parameter: services are provided with [`provide`](@ref) and read
with [`service`](@ref). Each step costs about 25–70 ns; use effects at I/O granularity, not in
inner loops. Binds are stack-safe at any depth.
"""
struct Effect{E, A}
    node::_ENode
end
_eff(::Type{E}, ::Type{A}, n::_ENode) where {E, A} = Effect{E, A}(n)

"Constructor tag of `Effect` (for `Upstream.pure(EffectTag(), x)`)."
struct EffectTag end

Base.show(io::IO, ::Effect{E, A}) where {E, A} = print(io, "Effect{", E, ", ", A, "}(…)")

# ---- Exceptions ------------------------------------------------------------------------------

"""
    EffectFailed(e)

Thrown by [`run`](@ref) and `fetch` on a [`Fiber`](@ref) when an effect fails with `Fail(e)`
and `e` is not an `Exception` (an exception `e` is thrown as itself). [`attempt`](@ref) and
[`fromtask`](@ref) turn it back into `Fail(e)`.
"""
struct EffectFailed{E} <: Exception
    e::E
end
Base.showerror(io::IO, x::EffectFailed) = print(io, "EffectFailed: the effect failed with ", repr(x.e))

"""
    Cancelled()

Thrown by [`run`](@ref) and `fetch` on a [`Fiber`](@ref) when the effect was interrupted, and by
[`checkcancel`](@ref) inside a `sync` when the fiber is cancelled. [`attempt`](@ref) and
[`fromtask`](@ref) turn it back into `Interrupted`.
"""
struct Cancelled <: Exception end
Base.showerror(io::IO, ::Cancelled) = print(io, "Cancelled: the effect was interrupted")

"""
    MissingService(S)

The defect (`Die`) of [`service`](@ref)`(S)` when no provided service is an `S`.
"""
struct MissingService <: Exception
    type::Any
end
Base.showerror(io::IO, x::MissingService) = print(io, "MissingService: no service of type ", x.type, " is provided")

# ---- Cause -----------------------------------------------------------------------------------

const _C_FAIL = 0x01
const _C_DIE = 0x02
const _C_INT = 0x03

"""
    Cause{E}

Why an effect did not succeed: the runtime's error channel (ADR-0002 §3). One of

- `Fail(e)`: an expected error `e::E` (from [`fail`](@ref), [`attempt`](@ref), [`fromtask`](@ref));
- `Die(ex, bt)`: a defect, an exception thrown inside the effect (from [`sync`](@ref)), with
  its backtrace;
- `Interrupted()`: the fiber was cancelled.

[`suppressed`](@ref)`(c)` lists the causes that were dropped in favour of this one (a scope's
later child failures, the second loser of [`race`](@ref), failing finalizers).
"""
struct Cause{E}
    tag::UInt8
    e::Union{Nothing, E}
    ex::Any
    bt::Any
    suppressed::Vector{Cause}
    Cause{E}(tag, e, ex, bt, suppressed) where {E} = new{E}(tag, e, ex, bt, suppressed)
end

"`Fail(e)`: the expected-error [`Cause`](@ref)."
Fail(e) = Cause{typeof(e)}(_C_FAIL, e, nothing, nothing, Cause[])
"`Die(ex, bt = nothing)`: the defect [`Cause`](@ref) of a thrown exception `ex`."
Die(ex, bt = nothing) = Cause{Union{}}(_C_DIE, nothing, ex, bt, Cause[])
"`Interrupted()`: the [`Cause`](@ref) of a cancelled fiber."
Interrupted() = Cause{Union{}}(_C_INT, nothing, nothing, nothing, Cause[])

"`isfail(c)`: whether the cause is a `Fail`."
isfail(c::Cause) = c.tag == _C_FAIL
"`isdie(c)`: whether the cause is a `Die`."
isdie(c::Cause) = c.tag == _C_DIE
"`isinterrupted(c)`: whether the cause is `Interrupted`."
isinterrupted(c::Cause) = c.tag == _C_INT
"`suppressed(c)`: the causes dropped in favour of `c`, oldest first (a fresh vector)."
suppressed(c::Cause) = copy(c.suppressed)

"`failure(c)`: the error of a `Fail`, or the exception of a `Die`; `nothing` for `Interrupted`."
failure(c::Cause) = c.tag == _C_FAIL ? c.e : c.tag == _C_DIE ? c.ex : nothing

# `c` with `others` appended to its suppressed list (a new value: causes are immutable).
function _suppress(c::Cause{E}, others...) where {E}
    s = copy(c.suppressed)
    for o in others
        push!(s, o)
    end
    return Cause{E}(c.tag, c.e, c.ex, c.bt, s)
end

function Base.:(==)(a::Cause, b::Cause)
    a.tag == b.tag || return false
    a.tag == _C_FAIL && return a.e == b.e
    a.tag == _C_DIE && return a.ex == b.ex
    return true
end
function Base.isequal(a::Cause, b::Cause)
    a.tag == b.tag || return false
    a.tag == _C_FAIL && return isequal(a.e, b.e)
    a.tag == _C_DIE && return isequal(a.ex, b.ex)
    return true
end
Base.hash(c::Cause, h::UInt) = hash(failure(c), hash(c.tag, hash(:Cause, h)))

function Base.show(io::IO, c::Cause)
    if c.tag == _C_FAIL
        print(io, "Fail(")
        show(io, c.e)
        print(io, ")")
    elseif c.tag == _C_DIE
        print(io, "Die(")
        show(io, c.ex)
        print(io, ")")
    else
        print(io, "Interrupted()")
    end
    isempty(c.suppressed) || print(io, " (", length(c.suppressed), " suppressed)")
    return nothing
end

# ---- Exit ------------------------------------------------------------------------------------

"""
    Exit{E,A}

The outcome of running an effect: `Success(a)` or `Failure(cause)`. The parameters come from the
outcome's own values (`Success(1)` is an `Exit{Union{},Int}`), so they are never stale.
"""
struct Exit{E, A}
    ok::Bool
    a::Union{Nothing, A}
    c::Union{Nothing, Cause{E}}
    Exit{E, A}(ok, a, c) where {E, A} = new{E, A}(ok, a, c)
end

"`Success(a)`: the [`Exit`](@ref) of an effect that succeeded with `a`."
Success(a) = Exit{Union{}, typeof(a)}(true, a, nothing)
"`Failure(c::Cause)`: the [`Exit`](@ref) of an effect that ended with cause `c`."
Failure(c::Cause{E}) where {E} = Exit{E, Union{}}(false, nothing, c)

"`succeeded(x::Exit)`: whether `x` is a `Success`."
succeeded(x::Exit) = x.ok
"`value(x::Exit)`: the value of a `Success`; throws an `ArgumentError` on a `Failure`."
value(x::Exit) = x.ok ? x.a : throw(ArgumentError("value of a Failure: $(x.c)"))
"`cause(x::Exit)`: the [`Cause`](@ref) of a `Failure`; throws an `ArgumentError` on a `Success`."
cause(x::Exit) = x.ok ? throw(ArgumentError("cause of a Success")) : something(x.c)

Base.:(==)(a::Exit, b::Exit) = a.ok == b.ok && (a.ok ? a.a == b.a : a.c == b.c)
Base.isequal(a::Exit, b::Exit) = a.ok == b.ok && (a.ok ? isequal(a.a, b.a) : isequal(a.c, b.c))
Base.hash(x::Exit, h::UInt) = x.ok ? hash(x.a, hash(:Success, h)) : hash(x.c, hash(:Failure, h))

function Base.show(io::IO, x::Exit)
    if x.ok
        print(io, "Success(")
        show(io, x.a)
    else
        print(io, "Failure(")
        show(io, x.c)
    end
    return print(io, ")")
end

# The exception `run`/`fetch` throw for a cause (ADR-0002 §3).
function _exception(c::Cause)
    c.tag == _C_DIE && return c.ex
    c.tag == _C_INT && return Cancelled()
    e = c.e
    return e isa Exception ? e : EffectFailed(e)
end
