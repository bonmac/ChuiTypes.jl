# Unit tests for streams (ADR-0003; phase-4 spec §2, §3, §5, §8). Concurrency and time are
# covered by the marble tests; this file checks values, fusion, chunking and lifecycles.

@testitem "Stream: sources, eltype, run functions" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    s = fromiter(1:5)
    @test s isa Stream{Int}
    @test eltype(s) === Int
    @test run(runcollect(s)) == [1, 2, 3, 4, 5]
    @test run(runcollect(s)) == [1, 2, 3, 4, 5]          # cold: a second run starts again
    @test run(runfold(+, 0, s)) == 15
    seen = Int[]
    @test run(runforeach(x -> push!(seen, x), s)) === nothing
    @test seen == 1:5
    @test run(runcollect(emptystream(Int))) == Int[]
    @test eltype(emptystream(Int)) === Int
    @test run(runcollect(fromeffect(succeed(3)))) == [3]
    @test StreamHelpers.thrown(() -> run(runcollect(failstream(ErrorException("x"))))) == ErrorException("x")
    # building a stream runs nothing
    calls = Ref(0)
    s2 = map(x -> (calls[] += 1; x), fromiter(1:3))
    @test calls[] == 0
    run(runcollect(s2))
    @test calls[] == 3
    # an iterable is re-iterated per run
    @test run(runcollect(fromiter((i^2 for i in 1:3)))) == [1, 4, 9]
    @test run(runcollect(fromiter(String[]))) == String[]
    @test run(runcollect(fromiter("ab"))) == ['a', 'b']
end

@testitem "Stream: chunks are ~1024, element operators fuse into one node" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: _Fused
    chunks = run(runchunks(fromiter(1:2500)))
    @test length.(chunks) == [1024, 1024, 452]
    @test length.(run(runchunks(fromiter(1:10; chunksize = 3)))) == [3, 3, 3, 1]
    @test_throws ArgumentError fromiter(1:3; chunksize = 0)
    s = filter(iseven, map(x -> x + 1, map(abs, fromiter(-5:5))))
    @test s.src isa _Fused
    @test !(s.src.src isa _Fused)                      # one node over the source
    @test run(runcollect(s)) == filter(iseven, map(x -> x + 1, map(abs, -5:5)))
    @test eltype(map(x -> x / 2, fromiter(1:3))) === Float64
    # filter that empties a chunk pulls again: chunks are never empty
    cs = run(runchunks(filter(>(2000), fromiter(1:2500))))
    @test all(!isempty, cs) && sum(length, cs) == 500
end

@testitem "Stream: scan, take, drop, takewhile carry state across chunks" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    xs = 1:3000
    @test run(runcollect(scan(+, 0, fromiter(xs)))) == cumsum(xs)
    @test run(runcollect(Iterators.take(fromiter(xs), 1500))) == 1:1500
    @test run(runcollect(Iterators.take(fromiter(xs), 0))) == Int[]
    @test run(runcollect(Iterators.drop(fromiter(xs), 1500))) == 1501:3000
    @test run(runcollect(Iterators.takewhile(<(2050), fromiter(xs)))) == 1:2049
    @test run(runcollect(Iterators.take(scan(+, 0, Iterators.drop(fromiter(xs), 10)), 3))) == [11, 23, 36]
    # take stops pulling: an unbounded source ends
    @test run(runcollect(Iterators.take(fromiter(Iterators.countfrom(1)), 2049))) == 1:2049
    @test run(runcollect(buffer(fromiter(1:7), 3))) == [[1, 2, 3], [4, 5, 6], [7]]
    # a take that finishes still runs complete, so a downstream buffer flushes (critic 7)
    @test run(runcollect(buffer(Iterators.take(fromiter(1:10), 5), 3))) == [[1, 2, 3], [4, 5]]
    # widening, never converting (ADR-0002 §1): an iterator whose eltype lies
    struct Liar end
    Base.iterate(::Liar, i = 1) = i > 3 ? nothing : (i == 2 ? 2.5 : i, i + 1)
    Base.eltype(::Type{Liar}) = Int
    Base.IteratorSize(::Type{Liar}) = Base.SizeUnknown()
    got = run(runcollect(fromiter(Liar())))
    @test isequal(got, [1, 2.5, 3]) && got[1] isa Int
    @test run(runcollect(map(x -> x == 2 ? "two" : x, fromiter(1:3)))) == [1, "two", 3]
    w = run(runcollect(window(fromiter(1:5), 2)))
    @test all(x -> x isa Stream, w)
    @test [run(runcollect(x)) for x in w] == [[1, 2], [3, 4], [5]]
end

@testitem "Stream: the fused sink widens per chunk and never touches an emitted chunk (phase 5)" tags = [:unit] begin
    using ChuiTypes
    struct Liar2 end
    Base.iterate(::Liar2, i = 1) = i > 7 ? nothing : (i == 3 ? 2.5 : i, i + 1)
    Base.eltype(::Type{Liar2}) = Int
    Base.IteratorSize(::Type{Liar2}) = Base.SizeUnknown()
    # chunk 2 (3:4) widens; chunk 3 is back on the typed fast path
    cs = run(runchunks(map(identity, fromiter(Liar2(); chunksize = 2))))
    @test isequal(cs, [[1, 2], [2.5, 4], [5, 6], [7]])
    @test eltype(cs[1]) === Int && eltype(cs[3]) === Int && eltype(cs[2]) === Real   # never converted
    @test cs[2][1] isa Float64 && cs[2][2] isa Int
    # runfold's typed accumulator (Int + Int -> Int) meets a Float64: it continues untyped
    @test run(runfold(+, 0, fromiter(Liar2(); chunksize = 2))) === 27.5
    @test run(runfold(+, 0, map(identity, fromiter(Liar2(); chunksize = 3)))) === 27.5
    @test run(runfold((a, x) -> a * x, 1, fromiter(1:5))) === 120
    @test isequal(run(runcollect(filter(x -> x != 4, map(identity, fromiter(Liar2()))))), [1, 2, 2.5, 5, 6, 7])
    # chunks are owned: later chunks never overwrite earlier ones (sparse, dense and widened)
    for s in (
            filter(x -> x % 97 == 0, fromiter(1:5000)), map(x -> 2x, fromiter(1:5000; chunksize = 100)),
            Iterators.take(scan(+, 0, fromiter(1:5000)), 4321),
        )
        chunks = run(runchunks(s))
        @test reduce(vcat, chunks) == run(runcollect(s))
        @test allunique(map(objectid, chunks))
    end
    sparse = run(runchunks(filter(x -> x % 1000 == 1, fromiter(1:5000))))
    @test sparse == [[1, 1001], [2001], [3001], [4001]]      # one output chunk per source chunk
end

@testitem "Stream: take closes the upstream at once (releases run, nothing more is pulled)" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    log = Symbol[]
    pulled = Ref(0)
    src = concatmap(bracketstream(sync(() -> (push!(log, :acq); 1)), (a, x) -> sync(() -> (push!(log, :rel); nothing)))) do _
        map(x -> (pulled[] += 1; x), fromiter(1:(10^6); chunksize = 10))
    end
    s = map(x -> (push!(log, :out); x), Iterators.take(src, 3))
    @test run(runcollect(s)) == [1, 2, 3]
    @test count(==(:acq), log) == 1 && count(==(:rel), log) == 1
    @test count(==(:out), log) == 3
    @test pulled[] <= 10
end

@testitem "Stream: errors are values; user throws become Die; catchfail" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: cause, isdie, isfail, failure
    err = ErrorException("boom")
    s = map(x -> x == 3 ? throw(err) : x, fromiter(1:5; chunksize = 1))
    x = runexit(runcollect(s))
    @test isdie(cause(x)) && failure(cause(x)) === err
    @test StreamHelpers.thrown(() -> run(runcollect(s))) === err
    # concat stops at the failure
    seen = Int[]
    x2 = runexit(runforeach(x -> push!(seen, x), concat(fromiter(1:2), failstream(:bad), fromiter(3:4))))
    @test isfail(cause(x2)) && failure(cause(x2)) === :bad && seen == [1, 2]
    # catchfail continues with the handler's stream; a Die is not caught
    @test run(runcollect(catchfail(e -> fromiter([e]), concat(fromiter([:a]), failstream(:b))))) == [:a, :b]
    @test isdie(cause(runexit(runcollect(catchfail(e -> fromiter([0]), s)))))
    # retry re-runs from the start after a Fail; emitted elements stay emitted
    n = Ref(0)
    flaky = concat(fromiter([1]), fromeffect(defer(() -> (n[] += 1; n[] < 3 ? fail(:again) : succeed(2)))))
    @test run(runcollect(retry(flaky, recurs(5)))) == [1, 1, 1, 2]
    n[] = 0
    x3 = runexit(runcollect(retry(flaky, recurs(1))))
    @test isfail(cause(x3)) && failure(cause(x3)) === :again
end

@testitem "Stream: concat, concatmap, merge, mergemap, switchmap (values)" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    @test run(runcollect(concat(fromiter(1:2), emptystream(Int), fromiter(3:4)))) == 1:4
    @test run(runcollect(concatmap(x -> fromiter(fill(x, x)), fromiter(1:3)))) == [1, 2, 2, 3, 3, 3]
    m = StreamHelpers.bounded(() -> run(runcollect(merge(fromiter(1:3000), fromiter(-3000:-1)))), "merge")
    @test sort(m) == sort(vcat(1:3000, -3000:-1))
    # chunk order within one input is kept
    @test filter(>(0), m) == 1:3000
    mm = StreamHelpers.bounded(() -> run(runcollect(mergemap(x -> fromiter(fill(x, 100)), fromiter(1:50); maxconcurrent = 4))), "mergemap")
    @test sort(mm) == sort(vcat((fill(x, 100) for x in 1:50)...))
    @test_throws ArgumentError mergemap(x -> fromiter([x]), fromiter(1:2); maxconcurrent = 0)
    # switchmap over an outer stream that ends at once: only the last inner is guaranteed
    sm = StreamHelpers.bounded(() -> run(runcollect(switchmap(x -> fromiter([x, x]), fromiter(1:3)))), "switchmap")
    @test sm[(end - 1):end] == [3, 3]
    @test run(runcollect(prefetch(fromiter(1:5000)))) == 1:5000
end

@testitem "Stream: withbatches and runchunks" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    s = fromiter(1:3000)
    total = withbatches(s) do it
        @test Base.IteratorSize(typeof(it)) == Base.SizeUnknown()
        sum(sum, it)
    end
    @test total == sum(1:3000)
    # the handle is invalid after f returns
    kept = withbatches(identity, s)
    @test_throws ArgumentError iterate(kept)
    # a failure throws from iterate, as run would
    err = ErrorException("w")
    @test StreamHelpers.thrown(() -> withbatches(it -> collect(it), concat(fromiter(1:2), failstream(err)))) === err
    # leaving f early closes the run (its release runs)
    rel = Ref(0)
    src = concatmap(_ -> fromiter(1:(10^6)), bracketstream(succeed(1), (a, x) -> sync(() -> (rel[] += 1; nothing))))
    first_chunk = withbatches(it -> first(it), src)
    @test length(first_chunk) == 1024 && rel[] == 1
    # runchunks with a bound
    @test run(runchunks(fromiter(1:10); maxelements = 10)) == [collect(1:10)]
    x = runexit(runchunks(fromiter(Iterators.countfrom(1)); maxelements = 5000))
    @test !ChuiTypes.succeeded(x) && ChuiTypes.failure(ChuiTypes.cause(x)) isa ArgumentError
end

@testitem "Stream: cancellation ends Interrupted and leaves no live fiber (test mode)" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: cause, isinterrupted
    rel = Ref(0)
    slow = concatmap(bracketstream(succeed(0), (a, x) -> sync(() -> (rel[] += 1; nothing)))) do _
        merge(interval(1.0), mergemap(x -> interval(0.5), fromiter(1:3)), switchmap(x -> interval(0.3), interval(2.0)))
    end
    prog = andthen(fork(runcollect(slow))) do f
        andthen(_ -> (interrupt!(f); await(f)), delay(10.0))
    end
    (x, c) = StreamHelpers.rt(prog)
    @test isinterrupted(cause(x))
    @test rel[] == 1
    @test StreamHelpers.settled(c) == 0
end

@testitem "Stream: a cancel during bracketstream's acquire still releases" tags = [:unit] setup = [StreamHelpers] begin
    # regression (:slow stress test): the acquire's scope was unmasked, so a cancel that arrived
    # during the acquire turned the acquired resource into Interrupted and it was never released
    using ChuiTypes
    using ChuiTypes: cause, isinterrupted
    acq, rel = Ref(0), Ref(0)
    self = Ref{Any}(nothing)
    res = bracketstream(sync(() -> (acq[] += 1; interrupt!(self[]); acq[])), (a, x) -> sync(() -> (rel[] += 1; nothing)))
    c = VirtualClock()
    f = start(runcollect(concatmap(_ -> fromiter(1:3), res)); clock = c)   # runs after start returns
    self[] = f
    StreamHelpers.waitfor(f)
    @test isinterrupted(cause(f.exit))
    @test acq[] == 1 && rel[] == 1
end

@testitem "Stream: operators that emit nothing still stop at a chunk boundary when cancelled" tags = [:unit] setup = [StreamHelpers] begin
    # regression (review B1): filter/drop/throttle re-pulled their upstream without the cancel
    # check, so a stream that emits nothing could never be interrupted
    using ChuiTypes
    using ChuiTypes: cause, isinterrupted
    ops = (
        "filter" => s -> filter(_ -> false, s),
        "drop" => s -> Iterators.drop(s, typemax(Int)),
        "throttle" => s -> throttle(s, 1.0e9),
    )
    for (name, op) in ops
        pulled = Ref(0)
        self = Ref{Any}(nothing)
        src = map(x -> (pulled[] += 1; x == 2 && interrupt!(self[]); x), fromiter(1:200_000; chunksize = 1))
        f = start(runcollect(op(src)); clock = VirtualClock())
        self[] = f
        StreamHelpers.waitfor(f; secs = 60)
        @test isinterrupted(cause(f.exit))
        @test pulled[] < 100                    # stopped at the next chunk, not at the end
    end
end

@testitem "Stream: releases behind concurrent operators see the run's exit; their failures fail it" tags = [:unit] setup = [StreamHelpers] begin
    # regression (review B2, S3): behind a pump a release saw Failure(Interrupted()) on a normal
    # end, and a failing release was dropped
    using ChuiTypes
    using ChuiTypes: Success, cause, isfail, failure
    ops = (
        "prefetch" => prefetch,
        "merge" => s -> merge(s, fromiter([7])),
        "debounce" => s -> debounce(s, 0.5),
        "buffertime" => s -> buffertime(s, 1.0),
        "mergemap outer" => s -> mergemap(x -> fromiter([x]), s),
        "switchmap outer" => s -> switchmap(x -> fromiter([x]), s),
        "mergemap inner" => s -> mergemap(_ -> s, fromiter([1])),
        "switchmap inner" => s -> switchmap(_ -> s, fromiter([1])),
    )
    for (name, op) in ops
        seen = Ref{Any}(nothing)
        ok = bracketstream(succeed(:h), (a, x) -> sync(() -> (seen[] = x; nothing)))
        (v, c) = StreamHelpers.rt(runcollect(op(ok)))
        @test v isa Vector
        @test seen[] == Success(:h)
        bad = bracketstream(succeed(:h), (a, x) -> fail(:release_failed))
        (cz, _) = StreamHelpers.rt(catchcause(c -> succeed(c), map(_ -> nothing, runcollect(op(bad)))))
        @test cz isa ChuiTypes.Cause && isfail(cz) && failure(cz) === :release_failed
    end
end

@testitem "Stream: buffertime windows agree with their Float64 boundaries" tags = [:unit] begin
    # review N6: floor((now - t0) / d) put an element at a boundary into the earlier window
    using ChuiTypes: _windowindex
    for d in (0.1, 0.3, 1.0 / 3, 0.7), k in 0:2000
        t = k * d                        # the boundary as the window ends compute it
        @test _windowindex(0.0, d, t) == k
        @test _windowindex(0.0, d, prevfloat(t)) == (k == 0 ? -1 : k - 1) || t == 0.0
    end
end

@testitem "Stream: functions that never return a stream (inferred Union{})" tags = [:unit] setup = [StreamHelpers] begin
    # regression (law tests): `eltype(Union{})` threw while building these streams
    using ChuiTypes
    using ChuiTypes: cause, isfail, isdie
    boom(x) = error("no stream for $x")
    for op in (concatmap, mergemap, switchmap)
        s = op(boom, fromiter(1:2))
        @test s isa Stream
        @test isdie(cause(StreamHelpers.bounded(() -> runexit(runcollect(s)), string(op))))
    end
    # the applicative over a failing stream of functions
    @test isfail(cause(runexit(runcollect(ChuiTypes.Upstream.ap(failstream(-1), fromiter(1:3))))))
end
