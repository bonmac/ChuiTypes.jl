# Precompile workload (phase-5 spec 2026-10-26-phase5-performance-design.md §4 T1).
#
# Dependency-free on purpose (lead decision 2026-10-26, not PrecompileTools; ADR-0005): the
# workload runs only while Julia generates this package's image, so the methods it reaches are
# cached there. Public API only. Every effect is `run` to completion: no fiber, task or timer
# outlives `_workload()` (spec T2; Aqua's persistent-tasks check is the gate, test/test_precompile.jl
# checks `livefibers()` and `orphans()`). Included last from src/ChuiTypes.jl.

function _workload()
    # Option, Either, Validation: map, Upstream.chain (Validation has no chain: Upstream.ap), foldl
    some(1); none(Int); right(String, 1); left("x", Int); valid(1, String); invalid("e", Int)
    foldl(+, Upstream.chain(x -> x > 0 ? some(x - 1) : none(Int), map(x -> x + 1, some(3))); init = 0)
    foldl(+, Upstream.chain(x -> x > 0 ? right(String, x - 1) : left("neg", Int), map(x -> x + 1, right(String, 3))); init = 0)
    foldl(+, Upstream.ap(map(x -> y -> x + y, valid(1, Vector{String})), valid(2, Vector{String})); init = 0)
    Upstream.ap(map(x -> y -> x + y, invalid(["e"], Int)), invalid(["f"], Int))
    # Effects: succeed / andthen / run, fork / await
    run(andthen(x -> succeed(x + 1), succeed(1)))
    run(andthen(f -> await(f), fork(succeed(5))))
    # State
    runstate(andthen(_ -> modifystate(x -> x * 2, Int), andthen(x -> putstate(Int, x + 1), getstate(Int))), 1)
    # Streams: fromiter over a range and a Vector, map / filter / scan, runcollect, runfold, merge
    run(runcollect(filter(iseven, map(x -> x + 1, fromiter(1:1000)))))
    run(runcollect(scan(+, 0, fromiter([1, 2, 3]))))
    run(runfold(+, 0, map(x -> x + 1, fromiter(1:1000))))
    run(runfold(+, 0, filter(isodd, fromiter(collect(1:100)))))
    run(runcollect(merge(fromiter(1:10), fromiter(1:10))))
    return nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1
    _workload()
end

# Non-closure entry points, for argument types the workload above does not reach.
precompile(fromiter, (UnitRange{Int},))
precompile(fromiter, (Vector{Int},))
precompile(fromiter, (Vector{Float64},))
precompile(some, (Int,))
precompile(none, (Type{Int},))
precompile(right, (Type{String}, Int))
precompile(left, (String, Type{Int}))
precompile(valid, (Int, Type{String}))
precompile(invalid, (String, Type{Int}))
precompile(succeed, (Int,))
precompile(getstate, (Type{Int},))
precompile(putstate, (Type{Int}, Int))
