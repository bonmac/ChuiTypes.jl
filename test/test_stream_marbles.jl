# Marble tests on virtual time (ADR-0003 §9; phase-4 spec §6, §13). Each test runs under
# `runtest` with its own VirtualClock and checks that the clock has no live fiber afterwards.
#
# Grammar (spec §13): one character is one frame; `-` empty; `(…)` a group in one frame; `|` end;
# `#` failure. Coverage of the brief's operator list (and the extras), by test item:
#   map, filter, scan, take, interval  -> "marbles: element operators"
#   merge, concat                       -> "marbles: merge and concat"
#   switchMap (switchmap)               -> "marbles: switchmap"
#   mergeMap (mergemap)                 -> "marbles: mergemap"
#   debounce, throttle                  -> "marbles: debounce and throttle"
#   buffer, window (count and time)     -> "marbles: buffer and window"
#   retry, catchfail                    -> "marbles: retry and catchfail"
#   prefetch (async boundary)           -> "marbles: merge and concat"
#   hot observables (Subject)           -> test_stream_hot.jl

@testmodule Marbles begin
    using Test
    using ChuiTypes
    using ChuiTypes: marbles, marbletrace
    "Trace `s` under a fresh VirtualClock; returns the string and the clock's live count after."
    function trace(s; kw...)
        c = VirtualClock()
        str = runtest(marbletrace(s; kw...); clock = c)
        t0 = time()
        while (@lock c.lock c.live) != 0 && time() - t0 < 10
            sleep(0.001)
        end
        return str, (@lock c.lock c.live)
    end
    "The trace string alone, after checking that the run left no live fiber."
    function tr(s; kw...)
        str, live = trace(s; kw...)
        @test live == 0
        return str
    end
    m(spec; kw...) = marbles(spec; kw...)
end

@testitem "marbles: the source and the trace round-trip" tags = [:unit] setup = [Marbles] begin
    using ChuiTypes
    for spec in ("|", "-|", "-a-b-c|", "a(bc)-|", "--(ab|)", "-a-#", "(a#)", "#")
        @test Marbles.tr(Marbles.m(spec); frames = 10) == spec
    end
    # without `|` or `#` a marble source never ends (RxJS): the trace is cut at `frames`
    @test Marbles.tr(Marbles.m("---"); frames = 3) == "---"
    @test Marbles.tr(Marbles.m("-a"); frames = 4) == "-a--"
    # values and a custom error
    s = Marbles.m("-a-b|"; values = (a = 1, b = 2))
    @test runtest(runcollect(s)) == [1, 2]
    @test eltype(s) === Int
    err = ErrorException("custom")
    @test (
        try
            runtest(runcollect(Marbles.m("-#"; error = err)))
        catch ex
            ex
        end
    ) === err
    # elements arrive at their frames: the virtual time of each
    times = runtest(runcollect(map(_ -> 0.0, Marbles.m("-a--b|"))) |> e -> andthen(_ -> clocktime(), e))
    @test times == 5.0
    @test_throws ArgumentError ChuiTypes.marbles("-a(b")
    @test_throws ArgumentError ChuiTypes.marbles("-a|b")
end

@testitem "marbles: element operators" tags = [:unit] setup = [Marbles] begin
    using ChuiTypes
    m = Marbles.m
    @test Marbles.tr(map(uppercase, m("-a-b-c|"))) == "-A-B-C|"
    @test Marbles.tr(filter(c -> iseven(c - '0'), m("-1-2-3-4|"))) == "---2---4|"
    @test Marbles.tr(map(x -> Char('0' + x), scan(+, 0, m("-a-b-c|"; values = (a = 1, b = 2, c = 3))))) == "-1-3-6|"
    @test Marbles.tr(Iterators.take(m("-a-b-c-d|"), 2)) == "-a-(b|)"
    @test Marbles.tr(Iterators.drop(m("-a-b-c-d|"), 2)) == "-----c-d|"
    @test Marbles.tr(Iterators.takewhile(!=('c'), m("-a-b-c-d|"))) == "-a-b-|"
    @test Marbles.tr(map(x -> Char('0' + x), Iterators.take(interval(1.0), 3))) == "-01(2|)"
    @test Marbles.tr(map(x -> Char('0' + x), Iterators.take(interval(2.0), 2))) == "--0-(1|)"
    # a failure in a user function is a failure at that frame
    @test Marbles.tr(map(c -> c == 'b' ? error("x") : c, m("-a-b-c|"))) == "-a-#"
end

@testitem "marbles: merge and concat" tags = [:unit] setup = [Marbles] begin
    using ChuiTypes
    m = Marbles.m
    @test Marbles.tr(merge(m("-a---b|"), m("--x-y--|"))) == "-ax-yb-|"
    # same-instant ties follow subscription order
    @test Marbles.tr(merge(m("-a|"), m("-b|"))) == "-(ab)|"
    @test Marbles.tr(merge(m("-b|"), m("-a|"))) == "-(ba)|"
    @test Marbles.tr(merge(m("-a|"), m("-b|"), m("-c-|"))) == "-(abc)-|"
    # the first failure fails the merge and stops the others
    @test Marbles.tr(merge(m("-a-#"), m("--b----c|"))) == "-ab#"
    @test Marbles.tr(concat(m("-a|"), m("-b|"))) == "-a-b|"
    @test Marbles.tr(concat(m("-a|"), m("#"))) == "-a#"
    @test Marbles.tr(concatmap(c -> m("-x-x|"; values = (x = c,)), m("-a-b|"))) == "--a-a-b-b|"
    @test Marbles.tr(prefetch(m("-a-b|"))) == "-a-b|"
end

@testitem "marbles: switchmap" tags = [:unit] setup = [Marbles] begin
    using ChuiTypes
    m = Marbles.m
    inner(c) = m("-x-x-x|"; values = (x = c,))
    # b arrives at 5: a's inner (subscribed at 1) is interrupted after emitting at 2 and 4
    @test Marbles.tr(switchmap(inner, m("-a---b---|"))) == "--a-a-b-b-b|"
    # the outer ends first: the stream ends with the last inner
    @test Marbles.tr(switchmap(inner, m("-a|"))) == "--a-a-a|"
    # an inner failure fails the stream; an old inner's failure after the switch is dropped
    @test Marbles.tr(switchmap(c -> c == 'a' ? m("-#") : m("-y|"), m("-a-b|"))) == "--#"
    @test Marbles.tr(switchmap(c -> c == 'a' ? m("---#") : m("-y-|"), m("-ab|"))) == "---y-|"
    # the outer failing fails the stream
    @test Marbles.tr(switchmap(inner, m("-a-#"))) == "--a#"
end

@testitem "marbles: mergemap" tags = [:unit] setup = [Marbles] begin
    using ChuiTypes
    m = Marbles.m
    inner(c) = m("-x-x|"; values = (x = c,))
    # a's and b's inners tie at 4: a was subscribed first
    @test Marbles.tr(mergemap(inner, m("-a-b|"))) == "--a-(ab)-b|"
    # maxconcurrent = 1: b waits for a's slot, as concatmap
    @test Marbles.tr(mergemap(inner, m("-a-b|"); maxconcurrent = 1)) == "--a-a-b-b|"
    @test Marbles.tr(mergemap(c -> c == 'b' ? m("#") : inner(c), m("-a-b|"))) == "--a#"
end

@testitem "marbles: debounce and throttle" tags = [:unit] setup = [Marbles] begin
    using ChuiTypes
    m = Marbles.m
    @test Marbles.tr(debounce(m("-ab----c---|"), 2.0)) == "----b----c-|"
    # ties are decided by time (spec §6): an arrival exactly at the deadline does not suppress
    # the kept element, whatever the timers' order; the end flushes the kept element
    @test Marbles.tr(debounce(m("a-b|"), 2.0)) == "--a(b|)"
    @test Marbles.tr(debounce(m("-a-b---c-|"), 2.0)) == "---a-b---(c|)"
    # a failure drops the kept element
    @test Marbles.tr(debounce(m("-a#"), 2.0)) == "--#"
    @test Marbles.tr(throttle(m("-abc-d---e|"), 3.0)) == "-a---d---e|"
    # one chunk at one instant: only its first element can pass
    @test Marbles.tr(throttle(m("-(ab)--c|"), 2.0)) == "-a--c|"
end

@testitem "marbles: buffer and window" tags = [:unit] setup = [Marbles] begin
    using ChuiTypes
    m = Marbles.m
    len(v) = Char('0' + length(v))
    wlen(w) = Char('0' + length(run(runcollect(w))))
    @test Marbles.tr(map(len, buffer(m("-a-b-c-d-e|"), 2))) == "---2---2--(1|)"
    @test Marbles.tr(map(wlen, window(m("-a-b-c-d-e|"), 2))) == "---2---2--(1|)"
    @test Marbles.tr(map(len, buffertime(m("-a-bc--d|"), 3.0))) == "---1--2-(1|)"
    @test Marbles.tr(map(wlen, windowtime(m("-a-bc--d|"), 3.0))) == "---1--2-(1|)"
    # empty windows are skipped; an element at a boundary belongs to the next window
    @test Marbles.tr(map(len, buffertime(m("---a------|"), 3.0))) == "------1---|"
    @test runtest(runcollect(buffertime(m("-a-bc--d|"), 3.0))) == [['a'], ['b', 'c'], ['d']]
    # an idle source schedules no window timers: a long quiet gap runs at once and ends
    @test Marbles.tr(map(len, buffertime(m("a" * "-"^60 * "b|"), 3.0)); frames = 70) == "---1" * "-"^58 * "(1|)"
end

@testitem "marbles: leases keep an outer resource open while inners use it" tags = [:unit] setup = [Marbles] begin
    using ChuiTypes
    m = Marbles.m
    log = Tuple{Symbol, Float64}[]
    res = bracketstream(
        andthen(t -> sync(() -> (push!(log, (:acq, t)); 'h')), clocktime()),
        (a, x) -> andthen(t -> sync(() -> (push!(log, (:rel, t)); nothing)), clocktime()),
    )
    # the outer (one element, then its end at once) ends long before the inner that reads it
    @test Marbles.tr(mergemap(h -> m("--x-x|"; values = (x = h,)), res)) == "--h-h|"
    @test log == [(:acq, 0.0), (:rel, 5.0)]
    empty!(log)
    @test Marbles.tr(switchmap(h -> m("-x|"; values = (x = h,)), res)) == "-h|"
    @test log == [(:acq, 0.0), (:rel, 2.0)]
    empty!(log)
    @test Marbles.tr(concatmap(h -> m("-x|"; values = (x = h,)), prefetch(res))) == "-h|"
    @test log == [(:acq, 0.0), (:rel, 2.0)]
end

@testitem "marbles: retry and catchfail" tags = [:unit] setup = [Marbles] begin
    using ChuiTypes
    m = Marbles.m
    @test Marbles.tr(retry(m("-a-#"), recurs(2))) == "-a--a--a-#"
    @test Marbles.tr(retry(m("-a-#"), recurs(2, spaced(1.0)))) == "-a---a---a-#"
    @test Marbles.tr(retry(m("-a-|"), recurs(2))) == "-a-|"
    @test Marbles.tr(catchfail(_ -> m("-z|"), m("-a-#"))) == "-a--z|"
end
