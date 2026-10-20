# Retry schedules (ADR-0002 §9, PROVISIONAL; spec §11).

"""
    ChuiTypes.Schedule(next)

A retry policy: `next(n)` is the delay in seconds before retry `n` (1-based), or `nothing` to
stop. Build one with [`recurs`](@ref), [`spaced`](@ref) or [`exponential`](@ref). PROVISIONAL.
"""
struct Schedule{F}
    next::F
end

"""
    recurs(n)
    recurs(n, s::Schedule)

At most `n` retries: with no delay, or with the delays of `s` (stopping earlier if `s` stops).
"""
recurs(n::Integer) = Schedule(i -> i <= n ? 0.0 : nothing)
recurs(n::Integer, s::Schedule) = Schedule(i -> i <= n ? s.next(i) : nothing)

"""
    spaced(d)

Retry forever, waiting `d` seconds before each retry. Bound it with [`recurs`](@ref)`(n, s)`.
"""
spaced(d::Real) = (x = Float64(d); Schedule(_ -> x))

"""
    exponential(base; factor = 2.0)

Retry forever, waiting `base * factor^(n - 1)` seconds before retry `n`.
"""
exponential(base::Real; factor::Real = 2.0) = (b = Float64(base); f = Float64(factor); Schedule(i -> b * f^(i - 1)))

"""
    retry(eff::Effect, s::Schedule)

Run `eff`; while it fails with `Fail(e)` and the schedule allows, wait the schedule's delay on the
environment's clock and run it again. Defects (`Die`) and interruption are not retried. After the
last allowed retry the failure stands. Stack-safe for any number of retries.
"""
Base.retry(e::Effect{E, A}, s::Schedule) where {E, A} = _eff(E, A, _retry(e, s, 1).node)

function _retry(e::Effect, s::Schedule, n::Int)
    return catchfail(e) do err
        d = s.next(n)
        d === nothing ? fail(err) : andthen(_ -> _retry(e, s, n + 1), delay(d))
    end
end
