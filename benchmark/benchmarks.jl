# BenchmarkTools SUITE (root ADR-0011), run by `julia scripts/ci.jl bench`.
# ADR-0001 §11: map/chain/fold chains over Option{Int}, Option{String}, Either{String,Int} and
# Validation{String,Int} (valid path). The zero-allocation assertions are unit tests
# (test/test_option.jl, test_either.jl, test_validation.jl); these track the time.
using BenchmarkTools
using ChuiTypes

const U = ChuiTypes.Upstream

half(x) = iseven(x) ? some(x ÷ 2) : none(Int)
opt_int(xs) = sum(x -> foldl(+, U.chain(half, map(y -> y + 1, U.chain(half, some(x)))); init = 0), xs)
opt_str(xs) = sum(s -> foldl((a, y) -> a + ncodeunits(y), map(identity, U.chain(y -> some(y), some(s))); init = 0), xs)
pos(x) = x > 0 ? right(String, x) : left("neg", Int)
either_chain(xs) = sum(x -> foldl(+, U.chain(pos, map(y -> y - 1, U.chain(pos, right(String, x)))); init = 0), xs)
val_chain(xs) = sum(x -> foldl(+, map(y -> 2y, U.ap(valid(y -> y + 1, String), valid(x, String))); init = 0), xs)

const SUITE = BenchmarkGroup()
const XS = collect(1:10_000)
const SS = [string(i) for i in 1:10_000]
SUITE["chains"] = BenchmarkGroup()
SUITE["chains"]["Option{Int}"] = @benchmarkable opt_int($XS)
SUITE["chains"]["Option{String}"] = @benchmarkable opt_str($SS)
SUITE["chains"]["Either{String,Int}"] = @benchmarkable either_chain($XS)
SUITE["chains"]["Validation{String,Int}"] = @benchmarkable val_chain($XS)

# Phase 3: the interpreted step costs of ADR-0002 §1 (effect) and ADR-0007 (State), per 10^4 binds.
function eff_chain(n)
    m = succeed(0)
    for _ in 1:n
        m = andthen(x -> succeed(x + 1), m)
    end
    return m
end
function state_chain(n)
    m = U.pure(ChuiTypes.StateTag{Int}(), 0)
    for _ in 1:n
        m = andthen(_ -> modifystate(s -> s + 1, Int), m)
    end
    return m
end
const EFF = eff_chain(10_000)
const ST = state_chain(10_000)
SUITE["interpreters"] = BenchmarkGroup()
SUITE["interpreters"]["Effect 10^4 binds"] = @benchmarkable run($EFF)
SUITE["interpreters"]["State 10^4 binds"] = @benchmarkable runstate($ST, 0)
SUITE["interpreters"]["Effect fork+await"] = @benchmarkable run(andthen(f -> await(f), fork(succeed(1))))

# Phase 4: ADR-0003's cost claims ("fused operators cost what an iterator does; concurrency costs
# per chunk, not per item"). Real clock. Per-element cost = median time / element count; the
# "base" entries are the plain-Base baselines for the same work. Inputs of 10^6 elements.
const SN = 10^6
const SV = collect(1:SN)
succ(x) = x + 1
stream_pipeline(n) = run(runcollect(filter(iseven, map(succ, fromiter(1:n)))))
base_pipeline(n) = filter(iseven, map(succ, 1:n))
stream_fold(n) = run(runfold(+, 0, map(succ, fromiter(1:n))))
# Over the Vector, not 1:n: LLVM folds the range version to a closed form (measured 0 ns).
base_fold(v) = foldl(+, Iterators.map(succ, v); init = 0)
stream_merge4(n) = (q = n ÷ 4; run(runfold(+, 0, merge((fromiter(1:q) for _ in 1:4)...))))
stream_prefetch(n) = run(runfold(+, 0, prefetch(fromiter(1:n))))
stream_mergemap(k, m) = run(runfold(+, 0, mergemap(_ -> fromiter(1:m), fromiter(1:k); maxconcurrent = 16)))
stream_mapfilterscan(v) = run(runfold(+, 0, scan(+, 0, filter(iseven, map(succ, fromiter(v))))))

"""
    streams_allocs_per_chunk(v = SV) -> (bytes_per_chunk, chunks)

Bytes allocated by a warmed run of the fused map/filter/scan pipeline over the Vector{Int} `v`,
divided by its number of source chunks (`fromiter`'s default chunk size). Reported, not asserted.
"""
function streams_allocs_per_chunk(v = SV)
    stream_mapfilterscan(v)
    stream_mapfilterscan(v)
    bytes = @allocated stream_mapfilterscan(v)
    chunks = cld(length(v), ChuiTypes._CHUNK)
    return bytes / chunks, chunks
end

SUITE["streams"] = BenchmarkGroup()
SUITE["streams"]["fused map/filter collect 10^6"] = @benchmarkable stream_pipeline($SN)
SUITE["streams"]["base map/filter collect 10^6"] = @benchmarkable base_pipeline($SN)
SUITE["streams"]["fused map runfold 10^6"] = @benchmarkable stream_fold($SN)
SUITE["streams"]["base map foldl 10^6"] = @benchmarkable base_fold($SV)
SUITE["streams"]["merge 4x2.5e5"] = @benchmarkable stream_merge4($SN)
SUITE["streams"]["prefetch 10^6"] = @benchmarkable stream_prefetch($SN)
SUITE["streams"]["mergemap 100x10^4 mc16"] = @benchmarkable stream_mergemap(100, 10^4)
SUITE["streams"]["fused map/filter/scan Vector 10^6"] = @benchmarkable stream_mapfilterscan($SV)

# Phase 5 (spec D9): the sources alone, the indexed path over a Vector and the generic iteration
# path (an iterator with a concrete eltype and state), and the per-bind allocations of the
# interpreters. Allocation budgets are asserted in test/test_perf.jl; these track the time.
source_vector(v) = run(runfold(+, 0, fromiter(v)))
source_generic(v) = run(runfold(+, 0, fromiter(Iterators.take(v, length(v)))))
SUITE["streams"]["fromiter Vector runfold 10^6"] = @benchmarkable source_vector($SV)
SUITE["streams"]["fromiter generic iterator runfold 10^6"] = @benchmarkable source_generic($SV)

"""
    interpreter_allocs_per_bind() -> (effect, state)

Allocations per bind of a warmed run of the 10^4-bind Effect and State chains above. Reported,
not asserted (test/test_perf.jl asserts them).
"""
function interpreter_allocs_per_bind()
    run(EFF), runstate(ST, 0)
    e = @allocations run(EFF)
    s = @allocations runstate(ST, 0)
    return e / 10_000, s / 10_000
end
