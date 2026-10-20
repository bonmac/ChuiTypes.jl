# Fibers, scopes and the entry points (ADR-0002 §2, §3, §5, §6; ADR-0006 §3; spec §6).

"""
    Fiber{E,A}

An owned handle on an effect running in its own task (ADR-0002 §2), made by [`fork`](@ref) or
[`start`](@ref). `E` and `A` are the effect's advisory parameters.

- [`interrupt!`](@ref)`(f)` signals cancellation; [`await`](@ref)`(f)` is an effect giving the
  fiber's [`Exit`](@ref).
- `fetch(f)` blocks the calling task and returns the value, or throws as [`run`](@ref) does:
  the original exception for `Die(ex)` and `Fail(ex::Exception)`, `EffectFailed(e)` for any
  other `Fail(e)`, `Cancelled()` for `Interrupted`. `wait(f)` blocks until the fiber ends. Both
  are plain blocking calls, not cancellable; inside effects use `await`.
"""
mutable struct Fiber{E, A}
    task::Union{Nothing, Task}
    cancel::_CancelState
    cond::Threads.Condition
    exit::Union{Nothing, Exit}
    waiters::Vector{_Waiter}
    rt::Union{Nothing, VirtualClock}
end
Fiber{E, A}(cs::_CancelState, rt) where {E, A} = Fiber{E, A}(nothing, cs, Threads.Condition(), nothing, _Waiter[], rt)

Base.show(io::IO, f::Fiber{E, A}) where {E, A} =
    print(io, "Fiber{", E, ", ", A, "}(", f.exit === nothing ? "running" : f.exit, ")")

_isdone(f::Fiber) = (@lock f.cond f.exit) !== nothing

# Register `w` to fire when `f` ends (at once if it has ended).
function _ondone!(f::Fiber, w::_Waiter)
    done = @lock f.cond begin
        f.exit === nothing && push!(f.waiters, w)
        f.exit !== nothing
    end
    done && _fire!(w)
    return nothing
end
function _offdone!(f::Fiber, w::_Waiter)
    @lock f.cond filter!(x -> x !== w, f.waiters)
    return nothing
end

function _complete!(f::Fiber, x::Exit)
    ws = @lock f.cond begin
        f.exit = x
        notify(f.cond)
        w = copy(f.waiters)
        empty!(f.waiters)
        w
    end
    for w in ws
        _fire!(w)
    end
    return nothing
end

"""
    interrupt!(f::Fiber) -> nothing

Signal cancellation to `f` and to every fiber it started; returns at once (ADR-0002 §5). The
fiber stops at its next step or runtime primitive, after running its finalizers. Use
[`await`](@ref) to wait for it.
"""
function interrupt!(f::Fiber)
    _cancel!(f.cancel)
    return nothing
end

function Base.wait(f::Fiber)
    @lock f.cond begin
        while f.exit === nothing
            wait(f.cond)
        end
    end
    return nothing
end

function Base.fetch(f::Fiber)
    wait(f)
    x = something(f.exit)
    succeeded(x) && return x.a
    throw(_exception(something(x.c)))
end

# Wait for a fiber to end: cancellable when `interruptible`. Returns whether it ended.
function _awaitfiber(f::Fiber, cs::_CancelState, interruptible::Bool, rt)
    _isdone(f) && return true
    w = _Waiter(rt)
    _ondone!(f, w)
    ok = _park!(w, cs, interruptible)
    ok || _offdone!(f, w)
    return ok
end

# Join every child of a scope. Returns false if the wait was cancelled (only when interruptible).
function _joinchildren!(s::_Scope, interruptible::Bool)
    while true
        f = @lock s.lock begin
            filter!(c -> !_isdone(c), s.children)
            isempty(s.children) ? nothing : first(s.children)
        end
        f === nothing && return true
        _awaitfiber(f, s.cancel, interruptible, f.rt) || return false
    end
    return
end

# A child failure (Fail or Die) fails the scope and cancels it (spec §6).
function _childfailed!(s::_Scope, c::Cause)
    first = @lock s.lock begin
        if s.failure === nothing
            s.failure = c
            true
        else
            push!(s.dropped, c)
            false
        end
    end
    first && _cancel!(s.cancel)
    return nothing
end

# Run `node` as a fiber body in the current task: wrapped in its own scope.
function _runbody(node::_ENode, ctx::_Ctx)
    return try
        _interpret(_ENode(_N_SCOPE, node), ctx)
    catch ex
        (Failure(Die(ex, catch_backtrace())), nothing)
    end
end

# Start a fiber in a new task. `scope` (or nothing for a root) supervises it when `supervised`.
function _spawn(node::_ENode, ::Type{E}, ::Type{A}, cs::_CancelState, env, rt, scope, supervised::Bool) where {E, A}
    f = Fiber{E, A}(cs, rt)
    ctx = _Ctx(cs, env, 0, nothing, rt)
    scope === nothing || @lock scope.lock push!(scope.children, f)
    Threads.atomic_add!(_LIVE, 1)
    _rtlive!(rt, 1)
    body = () -> begin
        x, _ = _runbody(node, ctx)
        if supervised && scope !== nothing && !succeeded(x) && !isinterrupted(something(x.c))
            _childfailed!(scope, something(x.c))
        end
        _complete!(f, x)
        _detach!(cs)
        Threads.atomic_sub!(_LIVE, 1)
        if rt !== nothing
            @lock rt.lock begin
                rt.live -= 1
                delete!(rt.tasks, current_task())
            end
        end
        x
    end
    if rt === nothing
        f.task = Threads.@spawn body()
    else
        t = Task(body)
        t.sticky = true
        @lock rt.lock push!(rt.tasks, t)
        f.task = t
        schedule(t)
    end
    return f
end
