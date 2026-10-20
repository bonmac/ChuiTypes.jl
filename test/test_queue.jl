# Unit tests for the runtime's bounded Queue (ADR-0002 §4, ADR-0003 §3; phase-4 spec §4).
# Every wait is bounded: `StreamHelpers.bounded` fails the item instead of hanging.

@testmodule StreamHelpers begin
    using Test
    using ChuiTypes

    "Run `f()` in a task; fail loudly if it has not finished within `secs` seconds."
    function bounded(f, name = "section"; secs = 60.0)
        t = Threads.@spawn f()
        t0 = time()
        while !istaskdone(t) && time() - t0 < secs
            sleep(0.002)
        end
        istaskdone(t) || error("`$name` did not finish within $secs s")
        return fetch(t)
    end

    "Wait for fiber `f` to end, or throw after `secs` seconds."
    function waitfor(f::Fiber; secs = 20.0)
        t0 = time()
        while f.exit === nothing
            time() - t0 > secs && error("fiber did not end within $secs s")
            sleep(0.0005)
        end
        return f
    end

    "`runtest` with a per-test clock; returns `(value, clock)` so tests can check `clock.live`."
    function rt(eff; timeout = 10.0)
        c = VirtualClock()
        v = runtest(eff; clock = c, timeout)
        return v, c
    end

    "Wait (bounded) until the clock's live test-mode fibers are back to `n`."
    function settled(c::VirtualClock, n = 0; secs = 10.0)
        t0 = time()
        while (@lock c.lock c.live) != n && time() - t0 < secs
            sleep(0.001)
        end
        return @lock c.lock c.live
    end

    "Run `eff`, returning the thrown exception (or `nothing`)."
    function thrown(f)
        try
            f()
            return nothing
        catch ex
            return ex
        end
    end
end

@testitem "Queue: FIFO, capacity, length, close" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: QueueClosed, Fail, cause, isfail, failure
    q = Queue{Int}(3)
    @test isopen(q) && length(q) == 0
    @test_throws ArgumentError Queue{Int}(0)
    run(andthen(_ -> andthen(_ -> offer(q, 3), offer(q, 2)), offer(q, 1)))
    @test length(q) == 3
    @test [run(receive(q)) for _ in 1:3] == [1, 2, 3]
    # close: drains, then fails with QueueClosed; offer fails at once
    run(offer(q, 7))
    close(q)
    @test !isopen(q)
    @test run(receive(q)) == 7
    x = runexit(receive(q))
    @test isfail(cause(x)) && failure(cause(x)) isa QueueClosed
    x = runexit(offer(q, 1))
    @test isfail(cause(x)) && failure(cause(x)) isa QueueClosed
end

@testitem "Queue: a full offer waits and is the backpressure; a take frees it" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    q = Queue{Int}(1)
    log = Int[]
    prog = andthen(fork(andthen(_ -> sync(() -> (push!(log, -1); nothing)), andthen(_ -> offer(q, 2), offer(q, 1))))) do f
        andthen(delay(1.0)) do _
            # the producer is parked on the second offer: only one item fits
            n = length(q)
            andthen(receive(q)) do a
                andthen(receive(q)) do b
                    map(_ -> (n, a, b), await(f))
                end
            end
        end
    end
    (v, c) = StreamHelpers.rt(prog)
    @test v == (1, 1, 2)
    @test log == [-1]
    @test StreamHelpers.settled(c) == 0
end

@testitem "Queue: waits are cancellable without closing the queue" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: isinterrupted, cause
    q = Queue{Int}(1)
    run(offer(q, 1))
    # a parked putter and a parked taker (on another, empty queue) are both woken by their own
    # cancellation; the shared queue stays open and usable
    e = Queue{Int}(1)
    prog = andthen(fork(offer(q, 2))) do p
        andthen(fork(receive(e))) do t
            andthen(delay(1.0)) do _
                interrupt!(p)
                interrupt!(t)
                andthen(await(p)) do xp
                    map(xt -> (xp, xt), await(t))
                end
            end
        end
    end
    (v, c) = StreamHelpers.rt(prog)
    @test isinterrupted(cause(v[1])) && isinterrupted(cause(v[2]))
    @test isopen(q) && length(q) == 1 && isopen(e)
    @test run(receive(q)) == 1
    @test StreamHelpers.settled(c) == 0
    # real time, a parked receive interrupted from outside
    f = start(receive(Queue{Int}(2)))
    sleep(0.01)
    interrupt!(f)
    StreamHelpers.waitfor(f)
    @test isinterrupted(cause(f.exit))
end

@testitem "Queue: internal deadline take, try put/take" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: _take!, _tryput!, _trytake!, _Ctx
    q = Queue{Int}(2)
    @test _tryput!(q, 1) && _tryput!(q, 2) && !_tryput!(q, 3)
    @test _trytake!(q) == (true, 1)
    @test _trytake!(q) == (true, 2)
    @test _trytake!(q) == (false, nothing)
    # deadline take under virtual time: :timeout at the deadline, the item if it arrives first
    prog = ChuiTypes._ctxeffect() do ctx
        t0 = ChuiTypes._now(ChuiTypes._clockof(ctx))
        r1 = _take!(q, ctx, t0 + 2.0)
        t1 = ChuiTypes._now(ChuiTypes._clockof(ctx))
        (r1, t1 - t0)
    end
    (v, _) = StreamHelpers.rt(prog)
    @test v == ((true, :timeout), 2.0)
    prog2 = andthen(fork(andthen(_ -> offer(q, 9), delay(1.0)))) do _
        ChuiTypes._ctxeffect(ctx -> _take!(q, ctx, ChuiTypes._now(ChuiTypes._clockof(ctx)) + 5.0))
    end
    (v2, _) = StreamHelpers.rt(prog2)
    @test v2 == (true, 9)
end
