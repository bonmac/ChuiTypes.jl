# Stream stress tests for leaks and cancellation (brief phase 4; spec §14). Tagged :slow.
# Per-test counters only: each section counts its own acquires and releases, and the test-mode
# sections check their own VirtualClock's live fibers. Every section has a hard bound.

@testitem "stress: streams interrupted at random leak nothing" tags = [:slow] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: isinterrupted, cause, succeeded
    bounded = StreamHelpers.bounded
    acq = Threads.Atomic{Int}(0)
    rel = Threads.Atomic{Int}(0)
    res(s) = concatmap(_ -> s, bracketstream(sync(() -> (Threads.atomic_add!(acq, 1); nothing)), (a, x) -> sync(() -> (Threads.atomic_add!(rel, 1); nothing))))
    leaf(n) = res(Iterators.take(interval(0.0002 * (1 + mod(n, 3))), 20))
    shapes = [
        n -> merge(leaf(n), leaf(n + 1), leaf(n + 2)),
        n -> mergemap(i -> leaf(i), fromiter(1:20); maxconcurrent = 4),
        n -> switchmap(i -> leaf(i), Iterators.take(interval(0.0005), 10)),
        n -> prefetch(debounce(merge(leaf(n), leaf(n + 1)), 0.0003)),
        n -> buffertime(mergemap(i -> leaf(i), fromiter(1:5)), 0.001),
        n -> concatmap(i -> merge(leaf(i), fromiter(1:100)), fromiter(1:5)),
    ]
    # 1. real time, in a child process of its own (so the process-wide fiber counter is this
    # test's counter, critic 11): 600 runs, each interrupted after a random delay
    child = """
    using ChuiTypes
    using ChuiTypes: isinterrupted, cause, succeeded, livefibers
    acq = Threads.Atomic{Int}(0); rel = Threads.Atomic{Int}(0)
    res(s) = concatmap(_ -> s, bracketstream(sync(() -> (Threads.atomic_add!(acq, 1); nothing)), (a, x) -> sync(() -> (Threads.atomic_add!(rel, 1); nothing))))
    leaf(n) = res(Iterators.take(interval(0.0002 * (1 + mod(n, 3))), 20))
    shapes = [
        n -> merge(leaf(n), leaf(n + 1), leaf(n + 2)),
        n -> mergemap(i -> leaf(i), fromiter(1:20); maxconcurrent = 4),
        n -> switchmap(i -> leaf(i), Iterators.take(interval(0.0005), 10)),
        n -> prefetch(debounce(merge(leaf(n), leaf(n + 1)), 0.0003)),
        n -> buffertime(mergemap(i -> leaf(i), fromiter(1:5)), 0.001),
        n -> concatmap(i -> merge(leaf(i), fromiter(1:100)), fromiter(1:5)),
    ]
    base = livefibers()
    nint = 0; nfail = 0
    for i in 1:600
        f = start(runcollect(shapes[mod1(i, length(shapes))](i)))
        sleep(rand() * 0.003)
        interrupt!(f)
        t0 = time()
        while f.exit === nothing && time() - t0 < 30
            sleep(0.0005)
        end
        f.exit === nothing && (println("HUNG ", i); exit(2))
        succeeded(f.exit) || (isinterrupted(cause(f.exit)) ? (global nint += 1) : (global nfail += 1))
    end
    t0 = time()
    while livefibers() != base && time() - t0 < 20
        sleep(0.01)
    end
    println("RESULT ", base, " ", livefibers(), " ", acq[], " ", rel[], " ", nint, " ", nfail)
    """
    loadpath = join(Base.load_path(), Sys.iswindows() ? ";" : ":")
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --threads=2 -e $child`, "JULIA_LOAD_PATH" => loadpath)
    out = bounded("real-time interrupts (child process)"; secs = 600) do
        read(cmd, String)
    end
    m = match(r"RESULT (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)", out)
    @test m !== nothing
    if m !== nothing
        base, after, a, r, nint, nfail = parse.(Int, m.captures)
        @test after == base                  # no leaked fiber in the child
        @test a == r && a > 0               # every resource released once
        @test nfail == 0 && nint > 0
    end
    # 2. test mode: 1000 runs on their own clocks, interrupted at random virtual times
    vacq = Ref(0)
    vrel = Ref(0)
    vres(s) = concatmap(_ -> s, bracketstream(sync(() -> (vacq[] += 1; nothing)), (a, x) -> sync(() -> (vrel[] += 1; nothing))))
    vleaf(n) = vres(Iterators.take(interval(0.5 * (1 + mod(n, 3))), 10))
    vshapes = [
        n -> merge(vleaf(n), vleaf(n + 1)),
        n -> mergemap(i -> vleaf(i), fromiter(1:6); maxconcurrent = 3),
        n -> switchmap(i -> vleaf(i), Iterators.take(interval(1.25), 5)),
        n -> debounce(merge(vleaf(n), vleaf(n + 2)), 0.75),
    ]
    live = bounded("virtual-time interrupts"; secs = 300) do
        worst = 0
        for i in 1:1000
            c = VirtualClock()
            prog = andthen(fork(runcollect(vshapes[mod1(i, length(vshapes))](i)))) do f
                andthen(_ -> (interrupt!(f); await(f)), delay(rand(0:40) / 4))
            end
            runtest(prog; clock = c)
            worst = max(worst, StreamHelpers.settled(c))
        end
        worst
    end
    @test live == 0
    @test vacq[] == vrel[]
    # 3. hot sources: 200 subjects with 5 subscribers each, closed or interrupted at random
    hot = bounded("subjects"; secs = 120) do
        worst = 0
        for i in 1:200
            c = VirtualClock()
            subj = Subject{Int}(; capacity = 4, overflow = (:block, :dropnewest, :dropoldest, :latest)[mod1(i, 4)])
            pubs = foldl((acc, x) -> andthen(_ -> andthen(_ -> publish(subj, x), delay(0.25)), acc), 1:20; init = succeed(nothing))
            subs = foldl((acc, k) -> andthen(_ -> map(_ -> nothing, fork(runcollect(subscribe(subj)))), acc), 1:5; init = succeed(nothing))
            prog = andthen(_ -> andthen(_ -> (isodd(i) ? close(subj) : nothing; succeed(nothing)), timeout(pubs, rand(1:8))), subs)
            # even runs: the subscribers are still running when the root body ends; the root
            # scope waits for them, so interrupt them through a close after the timeout instead
            runtest(andthen(_ -> (close(subj); succeed(nothing)), prog); clock = c)
            worst = max(worst, StreamHelpers.settled(c))
        end
        worst
    end
    @test hot == 0
    # 4. channels: 300 tochannel round trips closed early by the consumer
    chans = bounded("channels"; secs = 120) do
        a0, r0 = acq[], rel[]
        for i in 1:300
            ch = tochannel(res(fromiter(Iterators.countfrom(1))); size = 2)
            take!(ch)
            close(ch)
        end
        t0 = time()
        while acq[] - a0 != rel[] - r0 && time() - t0 < 30
            sleep(0.01)
        end
        (acq[] - a0, rel[] - r0)
    end
    @test chans[1] == chans[2] == 300
end
