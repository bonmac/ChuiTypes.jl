# Channel adapters (ADR-0006 §5; phase-4 spec §9). Real time; every wait bounded.

@testitem "fromchannel: items, close ends, close(ch, ex) and bind fail with the original" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: cause, isfail, failure
    ch = Channel{Int}(10)
    foreach(i -> put!(ch, i), 1:5)
    close(ch)
    @test eltype(fromchannel(ch)) === Int
    @test StreamHelpers.bounded(() -> run(runcollect(fromchannel(ch))), "closed") == 1:5
    # a producer task that closes with an exception
    err = ErrorException("chan")
    ch2 = Channel{Int}(2)
    t = Threads.@spawn (foreach(i -> put!(ch2, i), 1:3); close(ch2, err))
    x = StreamHelpers.bounded(() -> runexit(runcollect(fromchannel(ch2))), "exc")
    @test isfail(cause(x)) && failure(cause(x)) === err
    # bind: a TaskFailedException is unwrapped to the task's own exception
    ch3 = Channel{Int}(c -> (put!(c, 1); throw(err)))
    seen = Int[]
    x3 = StreamHelpers.bounded(() -> runexit(runforeach(x -> push!(seen, x), fromchannel(ch3))), "bind")
    @test seen == [1] && isfail(cause(x3)) && failure(cause(x3)) === err
    # a slow producer: chunks are partial (whatever is ready), never waiting to fill 1024
    ch4 = Channel{Int}(100)
    Threads.@spawn (
        for i in 1:3
            put!(ch4, i); sleep(0.01)
        end; close(ch4)
    )
    cs = StreamHelpers.bounded(() -> run(runchunks(fromchannel(ch4))), "partial")
    @test reduce(vcat, cs) == 1:3 && length(cs) >= 2
end

@testitem "fromchannel: cancelling an empty wait takes nothing and counts an orphan" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: orphans, isinterrupted, cause
    ch = Channel{Int}(4)
    o0 = orphans()
    f = start(runcollect(fromchannel(ch)))
    sleep(0.05)
    interrupt!(f)
    StreamHelpers.waitfor(f)
    @test isinterrupted(cause(f.exit))
    @test orphans() >= o0 + 1
    # the abandoned helper took nothing: the next consumer gets every item
    put!(ch, 1)
    put!(ch, 2)
    close(ch)
    @test StreamHelpers.bounded(() -> run(runcollect(fromchannel(ch))), "after") == [1, 2]
    # test mode: the helper is not a live test-mode fiber, so a virtual timeout expires
    empty = Channel{Int}(1)
    r = StreamHelpers.bounded(() -> runtest(timeout(runcollect(fromchannel(empty)), 1.0)), "test mode")
    @test r == none(Vector)
    close(empty)
end

@testitem "tochannel: elements, close at end, close(ch, ex) on failure, consumer close stops it" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    ch = tochannel(fromiter(1:2000); size = 8)
    @test ch isa Channel{Int}
    @test StreamHelpers.bounded(() -> collect(ch), "collect") == 1:2000
    err = ErrorException("out")
    ch2 = tochannel(concat(fromiter(1:3), failstream(err)))
    got = Int[]
    ex = StreamHelpers.bounded("failure") do
        try
            while true
                push!(got, take!(ch2))
            end
        catch e
            e
        end
    end
    @test got == 1:3 && ex === err
    # closing from the consumer side stops the producing fiber and closes the run
    rel = Threads.Atomic{Int}(0)
    src = concatmap(_ -> fromiter(Iterators.countfrom(1)), bracketstream(succeed(0), (a, x) -> sync(() -> (Threads.atomic_add!(rel, 1); nothing))))
    ch3 = tochannel(src; size = 4)
    @test take!(ch3) == 1
    close(ch3)
    t0 = time()
    while rel[] == 0 && time() - t0 < 10
        sleep(0.005)
    end
    @test rel[] == 1
    # closing the channel cancels a fiber parked upstream (ADR-0006 §5): no put! is pending
    rel2 = Threads.Atomic{Int}(0)
    quiet = concatmap(_ -> interval(3600.0), bracketstream(succeed(0), (a, x) -> sync(() -> (Threads.atomic_add!(rel2, 1); nothing))))
    ch5 = tochannel(quiet)
    sleep(0.05)
    close(ch5)
    t0 = time()
    while rel2[] == 0 && time() - t0 < 10
        sleep(0.005)
    end
    @test rel2[] == 1
    @test time() - t0 < 5
    # round trip: tochannel then fromchannel behaves like the original
    @test StreamHelpers.bounded(() -> run(runcollect(fromchannel(tochannel(fromiter(1:5000); size = 16)))), "round trip") == 1:5000
end
