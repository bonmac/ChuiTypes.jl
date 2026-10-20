# Leak stress tests (ADR-0002 §11; spec §12): many forks, races, timeouts and interrupts, then the
# live-fiber counter is back at its baseline and no orphan was created. Tagged :slow.

@testitem "stress: no leaked fibers" tags = [:slow] begin
    using ChuiTypes
    using ChuiTypes: livefibers, orphans
    # Items share one process: fibers that earlier items left running on purpose (the planted
    # escaping fork ends after 50 ms) must end before the baseline is taken.
    t0 = time()
    while livefibers() != 0 && time() - t0 < 10
        sleep(0.01)
    end
    base_live, base_orph = livefibers(), orphans()
    @test base_live == 0
    function settle(base)                 # finished tasks may still be decrementing
        t0 = time()
        while livefibers() != base && time() - t0 < 10
            sleep(0.01)
        end
        return livefibers()
    end
    # 1. 10^4 forks in one scope, each a few steps
    n = 10_000
    forks = foldl((acc, i) -> andthen(_ -> map(_ -> nothing, fork(map(x -> x + i, succeed(i)))), acc), 1:n; init = succeed(nothing))
    @test run(forks) === nothing
    @test settle(base_live) == base_live
    # 2. 2000 races and timeouts on real time, the losers interrupted
    for i in 1:1000
        @test run(race(delay(10), succeed(i))) == i
        @test run(timeout(delay(10), 0.0001)) == none(Nothing)
    end
    @test settle(base_live) == base_live
    # 3. 500 started fibers interrupted at random points while parked or running
    fibers = [start(andthen(_ -> delay(rand() * 0.01), sync(() -> sum(1:1000)))) for _ in 1:500]
    foreach(interrupt!, fibers)
    foreach(wait, fibers)
    @test settle(base_live) == base_live
    # 4. 200 failing scopes with 10 children each: siblings cancelled, nothing left
    for _ in 1:200
        prog = foldl((acc, i) -> andthen(_ -> map(_ -> nothing, fork(i == 5 ? fail(:x) : delay(10))), acc), 1:10; init = succeed(nothing))
        @test ChuiTypes.isfail(ChuiTypes.cause(runexit(prog)))
    end
    @test settle(base_live) == base_live
    # 5. test mode: 1000 virtual-time fibers
    vc = VirtualClock()
    prog = foldl((acc, i) -> andthen(_ -> map(_ -> nothing, fork(delay(i % 17))), acc), 1:1000; init = succeed(nothing))
    @test runtest(prog; clock = vc) === nothing
    @test vc.live == 0 && vc.parked == 0
    @test settle(base_live) == base_live
    @test orphans() == base_orph
    @info "stress: live fibers back at baseline" base_live livefibers() orphans()
end
