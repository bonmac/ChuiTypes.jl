"""
    ChuiTypes

Data types, effects and streams for the Chui ecosystem.

Phase 2 provides the core data types (ADR-0001): [`Option`](@ref), [`Either`](@ref),
[`Validation`](@ref), [`These`](@ref), [`NonEmpty`](@ref) and [`LazyList`](@ref). They are
concrete parametric structs whose operations infer concrete types and, for isbits and string
payloads, do not allocate.

Phase 3 adds [`Reader`](@ref), [`Writer`](@ref) and [`State`](@ref) (ADR-0007) and the one
effect runtime (ADR-0002, ADR-0006): [`Effect`](@ref) values run by [`run`](@ref) or
[`runexit`](@ref), with typed failures ([`Cause`](@ref), [`Exit`](@ref)), services
([`provide`](@ref)), cooperative cancellation ([`interrupt!`](@ref), [`checkcancel`](@ref)),
structured concurrency ([`fork`](@ref), [`scope`](@ref), [`race`](@ref), [`timeout`](@ref)),
resource safety ([`bracket`](@ref)), a virtual-time test mode ([`runtest`](@ref)) and the Task
adapters ([`async`](@ref), [`fromtask`](@ref), [`totask`](@ref)). `andthen` is the public bind.

Typeclass operations (`fmap`, `pure`, `ap`, `chain`, `alt`, `zeroalt`, `bimap`, `traverse`,
`combine`, `neutral`) live in the internal module `ChuiTypes.Upstream` and are **not public**:
their names follow the upstream core package once it is released (ADR-0004), and may change.
Use the Base functions (`map`, `iterate`, `foldl`, `get`, `show`) for stable behaviour.
"""
module ChuiTypes

using Compat: @compat
using ScopedValues: ScopedValues

export Option, some, none, issome, isnone
export Either, left, right, isleft, isright, fromleft, fromright
export Validation, valid, invalid, isinvalid, errors
export These
export NonEmpty, nonempty
export LazyList, lazylist, lazycons, lazynil

# Phase 3: Reader, Writer, State (ADR-0007)
export Reader, ask, asks, withreader, runreader
export Writer, tell, listening, censor, runwriter
export State, getstate, putstate, modifystate, runstate

# Phase 3: the effect runtime (ADR-0002, ADR-0006; spec 2026-10-20-phase3-effects-design.md §1)
export andthen
export Effect, succeed, fail, die, sync, attempt, defer
export Exit, Cause, runexit, EffectFailed, Cancelled, MissingService
export catchfail, catchcause, mapfail, provide, service
export checkcancel, uninterruptible, interruptiblemask, interrupt!, await
export Fiber, fork, start, scope, race, racefirst, timeout, timeoutfail, zippar
export bracket, acquirerelease, ensuring
export delay, clocktime, VirtualClock, advance!, runtest
export recurs, spaced, exponential
export async, fromtask, totask

@compat public this, that, both, isthis, isthat, isboth, here, there
@compat public ReaderTag, WriterTag, StateTag
@compat public EffectTag, fromexit, Success, Failure, Fail, Die, Interrupted
@compat public succeeded, isfail, isdie, isinterrupted, cause, value, failure, suppressed
@compat public RealClock, AbstractClock, Schedule, livefibers, orphans

# Token for the inner constructors: values are built only through the documented constructors.
struct _New end
const _NEW = _New()

include("upstream.jl")
include("common.jl")
include("option.jl")
include("either.jl")
include("validation.jl")
include("these.jl")
include("nonempty.jl")
include("lazylist.jl")
include("rws.jl")
include("reader.jl")
include("writer.jl")
include("state.jl")
include("effect/types.jl")
include("effect/context.jl")
include("effect/interpreter.jl")
include("effect/fiber.jl")
include("effect/api.jl")
include("effect/clock.jl")
include("effect/combinators.jl")
include("effect/schedule.jl")
include("effect/adapters.jl")

end # module ChuiTypes
