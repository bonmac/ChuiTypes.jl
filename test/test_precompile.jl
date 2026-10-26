# The precompile workload (src/precompile.jl; spec 2026-10-26-phase5-performance-design.md §4).
#
# :unit  T2, no residue: `_workload()` returns `nothing` and leaves no live fiber and no orphan
#        (Aqua's persistent-tasks check in test_package.jl is the gate for the package image).
# :slow  T3, regression ceiling: benchmark/ttfx.jl in fresh processes (one warm-up discarded,
#        minimum of 3); the workload total must be at most 0.6× the pre-workload baseline. It fails
#        only when the workload stopped working; the target (≤ 0.40 s on 1.13, ≤ 0.30 s on 1.10)
#        is not asserted. ADR-0009 cites the ceilings below (this file is their one source).

@testitem "precompile workload leaves no residue" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: livefibers, orphans
    # Items share one process: wait until the live-fiber count has been stable for 0.5 s.
    function stable()
        last, since, t0 = livefibers(), time(), time()
        while time() - since < 0.5 && time() - t0 < 15
            sleep(0.05)
            n = livefibers()
            n == last || (last = n; since = time())
        end
        return last
    end
    function settle(base)                 # finished tasks may still be decrementing
        t0 = time()
        while livefibers() != base && time() - t0 < 10
            sleep(0.01)
        end
        return livefibers()
    end
    base_live, base_orph = stable(), orphans()
    @test ChuiTypes._workload() === nothing
    @test settle(base_live) == base_live
    @test orphans() == base_orph
end

@testitem "TTFX regression ceiling (fresh process)" tags = [:slow] begin
    using ChuiTypes
    # Pre-workload baselines, workload total, median of 7 fresh processes, one thread, Apple M3
    # Pro: 1.69 s on 1.13.2, 1.23 s on 1.10.12 (spec §1 item 7; .lanes/evidence/ttfx-p5-08e9468.txt,
    # load average 1-min 5.4, 5/15-min 56–67: loaded). Re-measured on feat/phase5 339c806 with
    # benchmark/ttfx.jl: 1.77 s / 1.30 s (p5-ttfx-before-339c806.txt, load 1-min 4.9–5.6: loaded).
    # Ceiling = 0.6 × the spec's baseline.
    CEILING = Dict(v"1.13" => 1.0, v"1.10" => 0.75)
    vkey = VersionNumber(VERSION.major, VERSION.minor)
    if Base.JLOptions().code_coverage != 0
        @info "TTFX ceiling skipped under code coverage (package images are not used)"
        @test_skip false
    else
        script = pkgdir(ChuiTypes, "benchmark", "ttfx.jl")
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $script --reps 3`
        out = read(cmd, String)
        m = match(r"SUMMARY reps=3 min_total=(\S+) median_total=(\S+)", out)
        @test m !== nothing
        mintotal = parse(Float64, m.captures[1])
        @info "TTFX workload total, min of 3 fresh processes: $mintotal s (Julia $VERSION)"
        if haskey(CEILING, vkey)
            @test mintotal <= CEILING[vkey]
        else
            @info "no TTFX ceiling for Julia $vkey: measured only"
            @test_skip mintotal <= CEILING[v"1.13"]
        end
    end
end
