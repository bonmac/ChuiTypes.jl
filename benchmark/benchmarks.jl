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
