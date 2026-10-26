# Allocation budgets of the stream hot path and the interpreters (phase-5 spec D8; ADR-0009's
# allocation rows cite these numbers). Counts, not time: time rows live in benchmark/benchmarks.jl.
# Each case runs inside a function, after two warm-up calls. The bounds were calibrated as CI runs
# them (`julia scripts/ci.jl test`, i.e. Pkg.test with --check-bounds=yes) on 1.13 and 1.10.

@testmodule PerfBudgets begin
    using ChuiTypes
    const U = ChuiTypes.Upstream

    succ(x) = x + 1
    const N = 2^17                            # 128 source chunks of 1024
    const V = collect(1:N)
    const CHUNKS = cld(N, ChuiTypes._CHUNK)
    const NB = 10^4                           # binds per interpreter case

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
    const EFF = eff_chain(NB)
    const ST = state_chain(NB)

    # name => (thunk, units): allocations are reported per source chunk or per bind.
    const CASES = [
        :S1 => (() -> run(runcollect(filter(iseven, map(succ, fromiter(1:N))))), CHUNKS),
        :S2 => (() -> run(runfold(+, 0, map(succ, fromiter(1:N)))), CHUNKS),
        :S4 => (() -> run(runfold(+, 0, fromiter(V))), CHUNKS),
        :S4range => (() -> run(runfold(+, 0, fromiter(1:N))), CHUNKS),
        :generic => (() -> run(runfold(+, 0, fromiter(Iterators.take(V, N)))), CHUNKS),
        :effect => (() -> run(EFF), NB),
        :state => (() -> runstate(ST, 0), NB),
    ]

    # Budget rows (allocations per unit), keyed by VERSION.major.minor: the value measured by
    # `julia scripts/ci.jl test -- unit` at the phase-5 head (1.13.2 and 1.10.12, 2026-10-26),
    # rounded up to the next 0.5, plus 0.5 of headroom. Measured, 1.13: S1 6.88, S2 6.83, S4 3.72,
    # S4range 3.70, generic 4.72, effect 1.95, state 3.90; 1.10: S1 4.00, S2 4.02, S4 2.95,
    # S4range 2.93, generic 3.95, effect 1.96, state 3.90. (Before phase 5, 1.13, the same
    # cases under --check-bounds=yes outside Pkg.test: S1 22.0,
    # S2 25.9, S4 13.8, S4range 15.8, generic 15.8, effect 7.96, state 3.90.) 1.10 counts about
    # one allocation fewer per 1024-element Vector than 1.13 (measured): the rows differ by version.
    # Evidence: `.lanes/evidence/p5-perf-calib-*.txt` and `p5-perf-calib-lts-*.txt` (this item's
    # @info line), `p5-perf-red-budgets-*.txt` (before).
    const BUDGETS = Dict(
        v"1.13" => Dict(:S1 => 7.5, :S2 => 7.5, :S4 => 4.5, :S4range => 4.5, :generic => 5.5, :effect => 2.5, :state => 4.5),
        v"1.10" => Dict(:S1 => 4.5, :S2 => 5.0, :S4 => 3.5, :S4range => 3.5, :generic => 4.5, :effect => 2.5, :state => 4.5),
    )
    const REFERENCE = v"1.13"

    "Allocations per unit of a warmed `f()` (two warm-up calls, measured inside this function)."
    function perunit(f, units)
        f()
        f()
        return (@allocations f()) / units
    end

    "The bound for `name` on this Julia: its row, else a loose ceiling of 2x the reference row."
    function bound(name, v = VERSION)
        key = VersionNumber(v.major, v.minor)
        haskey(BUDGETS, key) && return BUDGETS[key][name], true
        return 2 * BUDGETS[REFERENCE][name], false
    end
end

@testitem "Allocation budgets: stream chunks and interpreter binds" tags = [:unit] setup = [PerfBudgets] begin
    using Test
    using .PerfBudgets: CASES, perunit, bound
    if Base.JLOptions().code_coverage != 0
        @info "allocation budgets skipped under coverage (instrumentation allocates)"
        @test_skip false
    else
        measured = Pair{Symbol, Float64}[]
        for (name, (f, units)) in CASES
            a = perunit(f, units)
            b, exact = bound(name)
            push!(measured, name => a)
            exact || @info "no budget row for Julia $(VERSION.major).$(VERSION.minor): loose ceiling" name a b
            a <= b || @error "allocation budget exceeded" name a b
            @test a <= b
        end
        @info "allocations per chunk (streams) / per bind (effect, state), Julia $VERSION" measured
    end
end
