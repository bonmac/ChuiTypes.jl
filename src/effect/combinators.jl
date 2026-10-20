# Racing, timeouts and parallel pairs (ADR-0002 §8; spec §8). Their children are unsupervised
# fibers of the enclosing scope: a child failure reaches only this combinator.

_exitof(f::Fiber) = something(@lock f.cond f.exit)

# Interrupt a fiber and wait for it, masked.
function _stop!(f::Fiber, ctx::_Ctx)
    interrupt!(f)
    _awaitfiber(f, ctx.cancel, false, ctx.rt)
    return nothing
end

# Wait for the first of `a`, `b` to end. Returns the one that ended (`a` on a tie), or nothing if
# the caller was cancelled first.
function _first(a::Fiber, b::Fiber, ctx::_Ctx)
    _isdone(a) && return a
    _isdone(b) && return b
    w = _Waiter(ctx.rt)
    _ondone!(a, w)
    _ondone!(b, w)
    ok = _park!(w, ctx.cancel, _interruptible(ctx))
    _offdone!(a, w)
    _offdone!(b, w)
    ok || return nothing
    return _isdone(a) ? a : b
end

_asresult(x::Exit) = x.ok ? (true, x.a) : (false, something(x.c))

function _race(ctx::_Ctx, ea::Effect, eb::Effect, firstoutcome::Bool)
    fa = _forkin(ctx, ea, false)
    fb = _forkin(ctx, eb, false)
    win = _first(fa, fb, ctx)
    if win === nothing
        _stop!(fa, ctx)
        _stop!(fb, ctx)
        return (false, Interrupted())
    end
    lose = win === fa ? fb : fa
    xw = _exitof(win)
    if firstoutcome || succeeded(xw)
        _stop!(lose, ctx)
        return _asresult(xw)
    end
    # the first one failed: the race goes to the other
    if !_awaitfiber(lose, ctx.cancel, _interruptible(ctx), ctx.rt)
        _stop!(lose, ctx)
        return (false, Interrupted())
    end
    xl = _exitof(lose)
    succeeded(xl) && return (true, xl.a)
    return (false, _suppress(something(xw.c), something(xl.c)))
end

"""
    race(a, b)

Run `a` and `b` in parallel; succeed with the first success, interrupting and awaiting the other.
If both fail, fail with the first cause, the second in its [`suppressed`](@ref) list.
"""
race(a::Effect, b::Effect) = _eff(Any, Any, _ENode(_N_PRIM, ctx -> _race(ctx, a, b, false)))

"""
    racefirst(a, b)

Run `a` and `b` in parallel; end as the first one to end (success or failure), interrupting and
awaiting the other.
"""
racefirst(a::Effect, b::Effect) = _eff(Any, Any, _ENode(_N_PRIM, ctx -> _race(ctx, a, b, true)))

function _zippar(ctx::_Ctx, ea::Effect, eb::Effect)
    fa = _forkin(ctx, ea, false)
    fb = _forkin(ctx, eb, false)
    win = _first(fa, fb, ctx)
    if win === nothing
        _stop!(fa, ctx)
        _stop!(fb, ctx)
        return (false, Interrupted())
    end
    other = win === fa ? fb : fa
    xw = _exitof(win)
    if !succeeded(xw)
        _stop!(other, ctx)
        return (false, something(xw.c))
    end
    if !_awaitfiber(other, ctx.cancel, _interruptible(ctx), ctx.rt)
        _stop!(other, ctx)
        return (false, Interrupted())
    end
    xo = _exitof(other)
    succeeded(xo) || return (false, something(xo.c))
    return (true, (_exitof(fa).a, _exitof(fb).a))
end

"""
    zippar(a, b)

Run `a` and `b` in parallel and succeed with `(x, y)`. The first failure interrupts and awaits the
other, and the pair fails with it.
"""
zippar(a::Effect{E1, A1}, b::Effect{E2, A2}) where {E1, A1, E2, A2} =
    _eff(Union{E1, E2}, _pairtype(A1, A2), _ENode(_N_PRIM, ctx -> _zippar(ctx, a, b)))
_pairtype(A1, A2) = (A1 === Union{} || A2 === Union{}) ? Union{} : Tuple{A1, A2}

"""
    timeout(eff::Effect{E,A}, d) -> Effect{E,Option{A}}

Run `eff` with a time limit of `d` seconds on the environment's clock: `some(x)` if it succeeds
in time, `none(A)` (`A` advisory) on expiry, after interrupting and awaiting it. A failure in time
is a failure.
"""
timeout(e::Effect{E, A}, d::Real) where {E, A} =
    _eff(E, Option{A}, racefirst(map(some, e), map(_ -> none(A), delay(d))).node)

"""
    timeoutfail(eff, d, err)

Like [`timeout`](@ref), but fail with `Fail(err)` on expiry and succeed with the plain value.
"""
timeoutfail(e::Effect{E, A}, d::Real, err) where {E, A} =
    _eff(Union{E, typeof(err)}, A, racefirst(e, andthen(_ -> fail(err), delay(d))).node)
