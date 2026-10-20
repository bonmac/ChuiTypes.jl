# Leak stress tests (ADR-0002 §11; spec §12): many forks, races, timeouts and interrupts, then the
# live-fiber counter is back at its baseline and no orphan was created. Tagged :slow.
#
# Every section runs under a wall-clock bound (`bounded`): a hang fails the item loudly instead of
# spinning. Sections return their results; the `@test`s run in the item's own task.

@testitem "stress: no leaked fibers" tags = [:slow] begin
    using ChuiTypes
    using ChuiTypes: livefibers, orphans
    function bounded(f, name; secs = 120.0)
        t = Threads.@spawn f()
        t0 = time()
        while !istaskdone(t) && time() - t0 < secs
            sleep(0.01)
        end
        istaskdone(t) || error("stress section `$name` did not finish within $secs s")
        return fetch(t)
    end
    # Items share one process: let fibers other items left running end first, then take the
    # baseline once it has been stable for 0.5 s (a stuck fiber of another item does not count
    # against this item).
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
    # 1. 10^4 forks in one scope, each a few steps
    n = 10_000
    forks = foldl((acc, i) -> andthen(_ -> map(_ -> nothing, fork(map(x -> x + i, succeed(i)))), acc), 1:n; init = succeed(nothing))
    @test bounded(() -> run(forks), "forks") === nothing
    @test settle(base_live) == base_live
    # 2. 2000 races and timeouts on real time, the losers interrupted
    ok = bounded("races") do
        all(i -> run(race(delay(10), succeed(i))) == i && run(timeout(delay(10), 0.0001)) == none(Nothing), 1:1000)
    end
    @test ok
    @test settle(base_live) == base_live
    # 3. 500 started fibers interrupted at random points while parked or running
    done = bounded("interrupts") do
        fibers = [start(andthen(_ -> delay(rand() * 0.01), sync(() -> sum(1:1000)))) for _ in 1:500]
        foreach(interrupt!, fibers)
        foreach(wait, fibers)
        all(f -> f.exit !== nothing, fibers)
    end
    @test done
    @test settle(base_live) == base_live
    # 4. 200 failing scopes with 10 children each: siblings cancelled, nothing left
    allfail = bounded("failing scopes") do
        all(1:200) do _
            prog = foldl((acc, i) -> andthen(_ -> map(_ -> nothing, fork(i == 5 ? fail(:x) : delay(10))), acc), 1:10; init = succeed(nothing))
            ChuiTypes.isfail(ChuiTypes.cause(runexit(prog)))
        end
    end
    @test allfail
    @test settle(base_live) == base_live
    # 5. test mode: 1000 virtual-time fibers
    vc = VirtualClock()
    prog = foldl((acc, i) -> andthen(_ -> map(_ -> nothing, fork(delay(i % 17))), acc), 1:1000; init = succeed(nothing))
    @test bounded(() -> runtest(prog; clock = vc), "test mode") === nothing
    @test vc.live == 0 && vc.parked == 0
    @test settle(base_live) == base_live
    @test orphans() == base_orph
    @info "stress: live fibers back at baseline" base_live livefibers() orphans()
end
