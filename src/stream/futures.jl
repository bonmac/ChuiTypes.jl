# Futures are effects (ADR-0006 §6; phase-4 spec §11): `collectpar`, Fluture's `parallel`.

function _collectpar(ctx::_Ctx, effs::Vector{Any}, maxc::Int)
    n = length(effs)
    results = Vector{Any}(undef, n)
    running = Tuple{Any, Int}[]            # (fiber, index), in start order: deterministic
    next = 1
    done = 0
    try
        while done < n
            while next <= n && length(running) < maxc
                push!(running, (_forkin(ctx, effs[next], false), next))
                next += 1
            end
            k = findfirst(r -> _isdone(r[1]), running)
            if k === nothing
                w = _Waiter(ctx.rt)
                for (f, _) in running
                    _ondone!(f, w)
                end
                ok = _park!(w, ctx.cancel, _interruptible(ctx))
                for (f, _) in running
                    _offdone!(f, w)
                end
                ok || return (false, Interrupted())
                continue
            end
            f, i = popat!(running, k)
            x = _exitof(f)
            succeeded(x) || return (false, something(x.c))
            results[i] = x.a
            done += 1
        end
    finally
        _stopall!([f for (f, _) in running], ctx)
    end
    return (true, map(identity, results))
end

"""
    collectpar(effs; maxconcurrent = 16) -> Effect{Any,Vector}

Run the effects `effs` concurrently, at most `maxconcurrent` at a time (the next starts when one
ends), and succeed with their values **in input order** (Fluture's `parallel`). The first failure
interrupts and awaits the others and fails with its cause. Cancellable.
"""
function collectpar(effs; maxconcurrent::Integer = 16)
    maxconcurrent >= 1 || throw(ArgumentError("collectpar: maxconcurrent must be at least 1, got $maxconcurrent"))
    v = Any[effs...]
    all(e -> e isa Effect, v) || throw(ArgumentError("collectpar takes effects"))
    return _primeffect(Any, Vector, ctx -> _collectpar(ctx, v, Int(maxconcurrent)))
end
