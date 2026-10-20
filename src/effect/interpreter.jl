# The trampoline (ADR-0002 §1, §4; spec §4). One loop per fiber with an explicit frame stack;
# it never recurses on bind depth.

const _F_MAP = 0x01         # a: f
const _F_BIND = 0x02        # a: k
const _F_CATCH = 0x03       # a: handler, b: kind
const _F_CTX = 0x04         # a: the _Ctx to restore
const _F_SCOPE = 0x05       # a: the _Scope, b: the outer _Ctx
const _F_ACQ = 0x06         # a: use, b: release, c: the outer _Ctx (bracket's acquire ran)
const _F_ACQREL = 0x07      # a: release, b: the outer _Ctx (acquirerelease's acquire ran)
const _F_FIN = 0x08         # a: rel(exit) returning an Effect
const _F_FINDONE = 0x09     # a: the Exit the finalizer saw, b: the _Ctx to restore

struct _Frame
    kind::UInt8
    a::Any
    b::Any
    c::Any
end
_Frame(kind::UInt8, a, b = nothing) = _Frame(kind, a, b, nothing)

# The node of a continuation's result; anything but an Effect is a defect.
@inline function _nodeof(x, what)
    x isa Effect && return x.node
    return _ENode(_N_FAIL, Die(ArgumentError("$what must return an Effect, got a $(typeof(x))")))
end

# How a throw inside `sync` (mode 0x00) or `attempt` (0x01) becomes a cause (spec §3).
function _classify(ex, bt, mode::UInt8, ctx::_Ctx)
    if ex isa Cancelled && _iscancelled(ctx.cancel)
        return Interrupted()
    end
    if mode == 0x01
        ex isa EffectFailed && return Fail(ex.e)
        ex isa Cancelled && return Interrupted()
        return Fail(ex)
    end
    return Die(ex, bt)
end

# A ^C at the root: cancel the whole tree this context belongs to (ADR-0002 §11).
function _rootcancel!(ctx::_Ctx)
    cs = ctx.cancel
    while true
        p = cs.parent
        p === nothing && break
        cs = p
    end
    _cancel!(cs)
    return nothing
end

const _MODE_EVAL = 0x00
const _MODE_VALUE = 0x01
const _MODE_FAIL = 0x02

"""
    _interpret(node, ctx) -> (Exit, sigint)

Run `node` to completion in the calling task. `sigint` is the `InterruptException` caught on the
way (best-effort ^C handling, ADR-0002 §11), or `nothing`.
"""
function _interpret(node::_ENode, ctx0::_Ctx)
    ctx = ctx0
    stack = _Frame[]
    cur = node
    mode = _MODE_EVAL
    val = nothing
    cause = Interrupted()
    sigint = nothing
    while true
        if mode == _MODE_EVAL
            if _interruptible(ctx) && _iscancelled(ctx.cancel)
                cause = Interrupted()
                mode = _MODE_FAIL
                continue
            end
            t = cur.tag
            if t == _N_PURE
                val = cur.a
                mode = _MODE_VALUE
            elseif t == _N_BIND
                push!(stack, _Frame(_F_BIND, cur.b))
                cur = cur.a::_ENode
            elseif t == _N_MAP
                push!(stack, _Frame(_F_MAP, cur.b))
                cur = cur.a::_ENode
            elseif t == _N_SYNC
                try
                    val = ScopedValues.with(cur.a, _CTX => ctx)
                    mode = _MODE_VALUE
                catch ex
                    if ex isa InterruptException
                        sigint = ex
                        _rootcancel!(ctx)
                    end
                    cause = _classify(ex, catch_backtrace(), cur.b::UInt8, ctx)
                    mode = _MODE_FAIL
                end
            elseif t == _N_FAIL
                cause = cur.a::Cause
                mode = _MODE_FAIL
            elseif t == _N_DEFER
                try
                    cur = _nodeof(cur.a(), "the function given to defer")
                catch ex
                    cause = Die(ex, catch_backtrace())
                    mode = _MODE_FAIL
                end
            elseif t == _N_CATCH
                push!(stack, _Frame(_F_CATCH, cur.b, cur.c))
                cur = cur.a::_ENode
            elseif t == _N_PROVIDE
                push!(stack, _Frame(_F_CTX, ctx))
                ctx = _withenv(ctx, _extend(ctx.env, cur.b))
                cur = cur.a::_ENode
            elseif t == _N_SERVICE
                found, v = _lookup(ctx.env, cur.a)
                if found
                    val = v
                    mode = _MODE_VALUE
                else
                    cause = Die(MissingService(cur.a))
                    mode = _MODE_FAIL
                end
            elseif t == _N_MASK
                push!(stack, _Frame(_F_CTX, ctx))
                ctx = _withmask(ctx, ctx.mask + 1)
                cur = cur.a::_ENode
            elseif t == _N_IMASK
                outer = ctx.mask
                restore = e -> Effect{Any, Any}(_ENode(_N_SETMASK, (e::Effect).node, outer))
                push!(stack, _Frame(_F_CTX, ctx))
                ctx = _withmask(ctx, ctx.mask + 1)
                try
                    cur = _nodeof(cur.a(restore), "the function given to interruptiblemask")
                catch ex
                    cause = Die(ex, catch_backtrace())
                    mode = _MODE_FAIL
                end
            elseif t == _N_SETMASK
                push!(stack, _Frame(_F_CTX, ctx))
                ctx = _withmask(ctx, cur.b::Int)
                cur = cur.a::_ENode
            elseif t == _N_SCOPE
                cs = _childcancel(ctx.cancel)
                s = _Scope(cs)
                push!(stack, _Frame(_F_SCOPE, s, ctx))
                ctx = _Ctx(cs, ctx.env, ctx.mask, s, ctx.rt)
                cur = cur.a::_ENode
            elseif t == _N_PRIM
                ok, r = try
                    cur.a(ctx)
                catch ex
                    if ex isa InterruptException
                        sigint = ex
                        _rootcancel!(ctx)
                    end
                    (false, Die(ex, catch_backtrace()))
                end
                if ok
                    val = r
                    mode = _MODE_VALUE
                else
                    cause = r::Cause
                    mode = _MODE_FAIL
                end
            elseif t == _N_BRACKET
                push!(stack, _Frame(_F_ACQ, cur.b, cur.c, ctx))
                ctx = _withmask(ctx, ctx.mask + 1)
                cur = cur.a::_ENode
            elseif t == _N_ACQREL
                push!(stack, _Frame(_F_ACQREL, cur.b, ctx))
                ctx = _withmask(ctx, ctx.mask + 1)
                cur = cur.a::_ENode
            elseif t == _N_CTX
                try
                    cur = _nodeof(cur.a(ctx), "an internal context function")
                catch ex
                    cause = Die(ex, catch_backtrace())
                    mode = _MODE_FAIL
                end
            else
                cause = Die(ErrorException("ChuiTypes: unknown effect node $(t)"))
                mode = _MODE_FAIL
            end
        elseif mode == _MODE_VALUE
            isempty(stack) && return (Success(val), sigint)
            fr = pop!(stack)
            k = fr.kind
            if k == _F_BIND
                try
                    cur = _nodeof(fr.a(val), "the function given to andthen")
                    mode = _MODE_EVAL
                catch ex
                    cause = Die(ex, catch_backtrace())
                    mode = _MODE_FAIL
                end
            elseif k == _F_MAP
                try
                    val = fr.a(val)
                catch ex
                    cause = Die(ex, catch_backtrace())
                    mode = _MODE_FAIL
                end
            elseif k == _F_CATCH
                # a success passes through a handler
            elseif k == _F_CTX
                ctx = fr.a::_Ctx
            elseif k == _F_SCOPE
                ctx, mode, val, cause = _scopeexit!(stack, fr.a::_Scope, fr.b::_Ctx, Success(val))
            elseif k == _F_ACQ
                a = val
                ctx = fr.c::_Ctx
                rel = fr.b
                push!(stack, _Frame(_F_FIN, x -> rel(a, x)))
                try
                    cur = _nodeof(fr.a(a), "bracket's use function")
                    mode = _MODE_EVAL
                catch ex
                    cause = Die(ex, catch_backtrace())
                    mode = _MODE_FAIL
                end
            elseif k == _F_ACQREL
                a = val
                ctx = fr.b::_Ctx
                rel = fr.a
                s = ctx.scope
                if s === nothing
                    cause = Die(ErrorException("acquirerelease outside a scope"))
                    mode = _MODE_FAIL
                else
                    @lock s.lock push!(s.finalizers, x -> rel(a, x))
                end
            elseif k == _F_FIN
                ctx, cur = _startfin!(stack, fr.a, Success(val), ctx)
                mode = _MODE_EVAL
            elseif k == _F_FINDONE
                saved = fr.a::Exit
                ctx = fr.b::_Ctx
                if succeeded(saved)
                    val = saved.a
                else
                    cause = something(saved.c)
                    mode = _MODE_FAIL
                end
            end
        else # _MODE_FAIL
            isempty(stack) && return (Failure(cause), sigint)
            fr = pop!(stack)
            k = fr.kind
            if k == _F_CATCH
                kind = fr.b::UInt8
                if (isfail(cause) || (kind == 0x02 && isdie(cause)))
                    h = fr.a
                    try
                        cur = _nodeof(kind == 0x01 ? h(cause.e) : h(cause), "the error handler")
                        mode = _MODE_EVAL
                    catch ex
                        cause = Die(ex, catch_backtrace())
                    end
                end
            elseif k == _F_CTX
                ctx = fr.a::_Ctx
            elseif k == _F_SCOPE
                ctx, mode, val, cause = _scopeexit!(stack, fr.a::_Scope, fr.b::_Ctx, Failure(cause))
            elseif k == _F_ACQ
                ctx = fr.c::_Ctx         # acquire failed: nothing to release
            elseif k == _F_ACQREL
                ctx = fr.b::_Ctx
            elseif k == _F_FIN
                ctx, cur = _startfin!(stack, fr.a, Failure(cause), ctx)
                mode = _MODE_EVAL
            elseif k == _F_FINDONE
                # the finalizer itself failed
                saved = fr.a::Exit
                ctx = fr.b::_Ctx
                cause = succeeded(saved) ? cause : _suppress(something(saved.c), cause)
            end
            # _F_BIND, _F_MAP: skipped
        end
    end
    return
end

# Run a finalizer `rel(exit)` masked; `_F_FINDONE` restores the outcome afterwards.
function _startfin!(stack, rel, x::Exit, ctx::_Ctx)
    push!(stack, _Frame(_F_FINDONE, x, ctx))
    mctx = _withmask(ctx, ctx.mask + 1)
    node = try
        _nodeof(rel(x), "a release function")
    catch ex
        _ENode(_N_FAIL, Die(ex, catch_backtrace()))
    end
    return mctx, node
end

# The exit of a scope (spec §6): join the children, decide the outcome, then run the scope's
# acquirerelease finalizers LIFO, masked, in the outer context.
function _scopeexit!(stack, s::_Scope, outer::_Ctx, x::Exit)
    if succeeded(x)
        if !_joinchildren!(s, _interruptible(outer))
            _cancel!(s.cancel)
            _joinchildren!(s, false)
        end
    else
        c = something(x.c)
        @lock s.lock begin
            if s.failure === nothing && !isinterrupted(c)
                s.failure = c
            elseif s.failure !== nothing && !isinterrupted(c) && s.failure !== c
                push!(s.dropped, c)
            end
        end
        _cancel!(s.cancel)
        _joinchildren!(s, false)
    end
    _detach!(s.cancel)
    out = @lock s.lock begin
        if s.failure !== nothing
            Failure(isempty(s.dropped) ? something(s.failure) : _suppress(something(s.failure), s.dropped...))
        elseif succeeded(x) && _iscancelled(s.cancel) && !_interruptible(outer)
            x       # cancelled from outside while masked: the body's success stands
        elseif succeeded(x) && _iscancelled(s.cancel)
            Failure(Interrupted())
        else
            x
        end
    end
    fins = @lock s.lock copy(s.finalizers)
    for f in fins                      # pushed first-registered first, so they run LIFO
        push!(stack, _Frame(_F_FIN, f))
    end
    if succeeded(out)
        return outer, _MODE_VALUE, out.a, Interrupted()
    else
        return outer, _MODE_FAIL, nothing, something(out.c)
    end
end
