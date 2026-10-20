# Constructors, combinators and the run functions (spec §3–§7).

# Advisory parameters of an effect-returning function's result type `R` (ADR-0001 §4's rule).
_effE(R) = _param(Effect, R, 1)
_effA(R) = _param(Effect, R, 2)
_ret(f, T...) = Base.promote_op(f, T...)

# ---- Values ----------------------------------------------------------------------------------

"""
    succeed(x) -> Effect{Union{},typeof(x)}

The effect that succeeds with `x`. Same as `Upstream.pure(EffectTag(), x)`.
"""
succeed(x) = _eff(Union{}, typeof(x), _ENode(_N_PURE, x))

"""
    fail(e) -> Effect{typeof(e),Union{}}

The effect that fails with the expected error `e` (cause `Fail(e)`). [`run`](@ref) throws `e`
itself when it is an `Exception`, else `EffectFailed(e)`.
"""
fail(e) = _eff(typeof(e), Union{}, _ENode(_N_FAIL, Fail(e)))

"""
    die(ex) -> Effect{Union{},Union{}}

The effect that fails with the defect `ex` (cause `Die(ex)`), as if `ex` had been thrown.
"""
die(ex) = _eff(Union{}, Union{}, _ENode(_N_FAIL, Die(ex)))

_failcause(c::Cause{E}) where {E} = _eff(E, Union{}, _ENode(_N_FAIL, c))

"""
    sync(f) -> Effect{Union{},A}

The effect that calls `f()` when run and succeeds with its result: the brief's IO value
(ADR-0006 §6). Anything `f` throws is a defect, `Die(ex)`; a [`Cancelled`](@ref) thrown by
[`checkcancel`](@ref) while the fiber is cancelled ends the effect `Interrupted`. A [`run`](@ref)
inside `f` runs under the same fiber (its cancellation and environment).
"""
sync(f) = _eff(Union{}, _ret(f), _ENode(_N_SYNC, f, 0x00))

"""
    attempt(f) -> Effect{Exception,A}

Like [`sync`](@ref), but an exception `f` throws is an expected error, `Fail(ex)`, so
[`catchfail`](@ref) sees it. `EffectFailed(e)` becomes `Fail(e)` and `Cancelled()` becomes
`Interrupted` (ADR-0006 §4).
"""
attempt(f) = _eff(Exception, _ret(f), _ENode(_N_SYNC, f, 0x01))

"""
    defer(f) -> Effect

The effect that calls `f()` when run and runs the effect it returns: for recursion and for
effects that must be rebuilt on each run.
"""
defer(f) = (R = _ret(f); _eff(_effE(R), _effA(R), _ENode(_N_DEFER, f)))

"""
    fromexit(x::Exit) -> Effect

The effect that ends as `x` did: succeeds with its value or fails with its cause.
"""
fromexit(x::Exit) = x.ok ? succeed(x.a) : _failcause(something(x.c))

# ---- Sequencing --------------------------------------------------------------------------------

"""
    map(f, eff::Effect)

The effect that runs `eff` and succeeds with `f` of its value. A throw in `f` is a `Die`.
"""
Base.map(f, e::Effect{E, A}) where {E, A} = _eff(E, _ret(f, A), _ENode(_N_MAP, e.node, f))

function andthen(k, e::Effect{E, A}) where {E, A}
    R = _ret(k, A)
    return _eff(Union{E, _effE(R)}, _effA(R), _ENode(_N_BIND, e.node, k))
end

# ---- Errors --------------------------------------------------------------------------------------

"""
    catchfail(h, eff::Effect)

Run `eff`; if it fails with `Fail(e)`, run `h(e)` (an effect) in its place. Defects (`Die`) and
interruption pass through.
"""
function catchfail(h, e::Effect{E, A}) where {E, A}
    R = _ret(h, E)
    return _eff(_effE(R), Union{A, _effA(R)}, _ENode(_N_CATCH, e.node, h, 0x01))
end

"""
    catchcause(h, eff::Effect)

Run `eff`; if it fails with `Fail` or `Die`, run `h(cause::Cause)` in its place. Interruption
cannot be caught: a cancelled fiber runs only its finalizers.
"""
function catchcause(h, e::Effect{E, A}) where {E, A}
    R = _ret(h, Cause{E})
    return _eff(_effE(R), Union{A, _effA(R)}, _ENode(_N_CATCH, e.node, h, 0x02))
end

"""
    mapfail(f, eff::Effect)

Run `eff`; if it fails with `Fail(e)`, fail with `Fail(f(e))` instead.
"""
mapfail(f, e::Effect{E, A}) where {E, A} =
    _eff(_ret(f, E), A, _ENode(_N_CATCH, e.node, x -> fail(f(x)), 0x01))

# ---- Environment --------------------------------------------------------------------------------

"""
    provide(eff, services...)

Run `eff` with `services` added to its environment, innermost first; each is found by
[`service`](@ref) through its type. Forked fibers inherit the environment. A clock
(`VirtualClock()`, an `AbstractClock`) is a service too.
"""
provide(e::Effect{E, A}, services...) where {E, A} = _eff(E, A, _ENode(_N_PROVIDE, e.node, Any[services...]))

"""
    service(S) -> Effect{Union{},S}

The innermost provided service `v isa S`. Without one the effect dies with
[`MissingService`](@ref)`(S)`. `service(ChuiTypes.AbstractClock)` falls back to `RealClock()`.
"""
service(::Type{S}) where {S} = _eff(Union{}, S, _ENode(_N_SERVICE, S))

# ---- Masking ------------------------------------------------------------------------------------

"""
    uninterruptible(eff)

Run `eff` masked: a cancel of this fiber takes effect only after `eff` ends (ADR-0002 §4). Runtime
primitives inside it wait without cancellation.
"""
uninterruptible(e::Effect{E, A}) where {E, A} = _eff(E, A, _ENode(_N_MASK, e.node))

"""
    interruptiblemask(f)

Run `f(restore)` masked, where `restore(eff)` runs `eff` with the cancellation status from
outside the call: for an acquire step that waits interruptibly but must not be interrupted
after the resource is held.
"""
interruptiblemask(f) = _eff(Any, Any, _ENode(_N_IMASK, f))

# ---- Scopes and fibers ---------------------------------------------------------------------------

"""
    scope(eff)

Run `eff` as a structured-concurrency scope (ADR-0002 §6): every fiber [`fork`](@ref)ed inside
belongs to it, and the scope waits for all of them before it ends. The first child that fails
(`Fail` or `Die`) cancels the scope, its body and the other children, and the scope fails with
that cause, even if the parent awaited the child. Interrupted children never fail a scope. Every
run and every fiber body is already a scope; `scope` makes a narrower one.
"""
scope(e::Effect{E, A}) where {E, A} = _eff(E, A, _ENode(_N_SCOPE, e.node))

# The cancel state of a combinator's internal child (race, timeout, zippar, fromtask(f)). In a
# masked region it is detached from the fiber's, so an outside cancel cannot reach the child
# while the region is masked (ADR-0002 §4): the combinator stops its children itself. A user
# `fork` stays a child of the scope's cancel state even when masked, so its scope can stop it.
_innercancel(ctx::_Ctx) = _interruptible(ctx) ? _childcancel(ctx.cancel) : _CancelState()

_forkin(ctx::_Ctx, e::Effect{E, A}, supervised::Bool) where {E, A} = _spawn(
    e.node, E, A, supervised ? _childcancel(ctx.cancel) : _innercancel(ctx),
    ctx.env, ctx.rt, ctx.scope, supervised,
)

"""
    fork(eff) -> Effect{Union{},Fiber}

Start `eff` in a new fiber that belongs to the enclosing [`scope`](@ref) and succeed with its
[`Fiber`](@ref) at once. The fiber inherits the environment, starts unmasked, and is cancelled
with its scope. In test mode it is a sticky task on the caller's thread.

A scope waits for its children: `fork(forever)` without an `interrupt!` keeps the parent alive.
A fiber forked inside a masked region ([`uninterruptible`](@ref)) is still cancelled with its
scope and its fiber; the hidden children of `race`, `timeout`, `zippar` and `fromtask(f)` in a
masked region are not, so those combinators finish when used in a release.
"""
fork(e::Effect{E, A}) where {E, A} = _eff(Union{}, Fiber{E, A}, _ENode(_N_PRIM, ctx -> (true, _forkin(ctx, e, true))))

"""
    await(f::Fiber) -> Effect{Union{},Exit}

Wait for `f` to end and succeed with its [`Exit`](@ref). The wait is cancellable (ADR-0002 §5).
Use [`fromexit`](@ref) to continue as the fiber ended.
"""
await(f::Fiber) = _eff(
    Union{}, Exit, _ENode(
        _N_PRIM, ctx -> _awaitfiber(f, ctx.cancel, _interruptible(ctx), ctx.rt) ?
            (true, something(@lock f.cond f.exit)) : (false, Interrupted())
    )
)

# Run an effect as a root in the calling task, or nested under the fiber of the enclosing `sync`.
function _runroot(e::Effect)
    amb = _CTX[]
    ctx = if amb === nothing
        _Ctx(_CancelState(), nothing, 0, nothing, nothing)
    else
        _Ctx(_childcancel(amb.cancel), amb.env, amb.mask, nothing, amb.rt)
    end
    Threads.atomic_add!(_LIVE, 1)
    try
        return _runbody(e.node, ctx)
    finally
        _detach!(ctx.cancel)
        Threads.atomic_sub!(_LIVE, 1)
    end
end

"""
    runexit(eff) -> Exit

Run `eff` in the calling task (as a root fiber, or under the enclosing `sync`'s fiber) and return
its [`Exit`](@ref). An `InterruptException` (^C) cancels the run, runs its finalizers best-effort,
and is rethrown.
"""
function runexit(e::Effect)
    x, sigint = _runroot(e)
    sigint === nothing || throw(sigint)
    return x
end

"""
    run(eff::Effect)
    run(eff::Effect, T)

Run `eff` in the calling task and return its value, or throw (ADR-0002 §3): the original
exception for `Die(ex)` and for `Fail(ex)` with `ex isa Exception` (`===` the thrown object; its
backtrace is on the `Die` cause from [`runexit`](@ref)), `EffectFailed(e)` for any other
`Fail(e)`, and `Cancelled()` when interrupted. With `T`, the value is asserted to be a `T`.
"""
function Base.run(e::Effect)
    x = runexit(e)
    succeeded(x) && return x.a
    throw(_exception(something(x.c)))
end
Base.run(e::Effect, ::Type{T}) where {T} = run(e)::T

"""
    start(eff; clock = nothing) -> Fiber

Start `eff` as a new root fiber in its own task and return its [`Fiber`](@ref) (not part of
any scope). With `clock = VirtualClock()`, the fiber and everything it forks run in **test
mode** (ADR-0002 §10) on the caller's thread; drive time with [`advance!`](@ref).
"""
function start(e::Effect{E, A}; clock = nothing) where {E, A}
    rt = clock isa VirtualClock ? clock : nothing
    env = clock === nothing ? nothing : _Env(clock, nothing)
    return _spawn(e.node, E, A, _CancelState(), env, rt, nothing, false)
end

# ---- Resources ----------------------------------------------------------------------------------

"""
    bracket(acquire, use, release)

Run `acquire` (an effect) masked, then `use(a)` (an effect), then `release(a, exit)` (an effect)
masked, with `use`'s [`Exit`](@ref), however `use` ends: success, failure or interruption
(ADR-0002 §7). Nested brackets release LIFO. A failing release fails a successful bracket; after
a failed `use`, a release failure is added to the cause's [`suppressed`](@ref) list. If `acquire`
fails, nothing is released.
"""
function bracket(acquire::Effect{E, A}, use, release) where {E, A}
    R = _ret(use, A)
    return _eff(Any, _effA(R), _ENode(_N_BRACKET, acquire.node, use, release))
end

"""
    acquirerelease(acquire, release)

Run `acquire` masked and succeed with its value `a`; `release(a, exit)` (an effect) runs masked
when the enclosing [`scope`](@ref) ends, with the scope's [`Exit`](@ref) as earlier releases
left it (a failing release turns a success into that failure for the releases after it).
Releases registered in one scope run LIFO.
"""
acquirerelease(acquire::Effect{E, A}, release) where {E, A} =
    _eff(E, A, _ENode(_N_ACQREL, acquire.node, release))

"""
    ensuring(eff, fin)

Run `eff`, then the effect `fin` masked, however `eff` ends.
"""
ensuring(e::Effect{E, A}, fin::Effect) where {E, A} =
    _eff(Any, A, _ENode(_N_BRACKET, succeed(nothing).node, _ -> e, (_, _) -> fin))

# ---- Typeclass stand-ins (ADR-0004) --------------------------------------------------------------

Upstream.fmap(f, e::Effect) = map(f, e)
Upstream.pure(::EffectTag, x) = succeed(x)
Upstream.ap(ff::Effect, fx::Effect) = andthen(f -> map(f, fx), ff)
Upstream.chain(k, e::Effect) = andthen(k, e)
Upstream.constructorclass(::Type{<:Effect}) = EffectTag()
