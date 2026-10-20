# Fluture-style futures are effects (ADR-0006 §6; phase-4 spec §11).
#
# Fluture             ChuiTypes
# Future(computation) async(register)            (register returns the canceller)
# resolve / reject    succeed / fail
# fork(rej, res)(f)   start(f) / run(f)          (lazy until then)
# cancel()            interrupt!(fiber)           (runs the canceller)
# chain / map         andthen / map
# both / race         zippar / race
# parallel(n, fs)     collectpar(fs; maxconcurrent = n)

@testitem "futures: lazy, cancellable, composable" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: Success, isinterrupted, cause
    started = Ref(0)
    cancelled = Ref(0)
    fut = async(
        cb -> begin
            started[] += 1
            t = Timer(_ -> cb(Success(42)), 0.05)
            () -> (cancelled[] += 1; close(t); cb(Success(-1)))
        end
    )
    @test started[] == 0                                   # lazy
    @test run(map(x -> x + 1, fut)) == 43 && started[] == 1
    @test run(fut) == 42 && started[] == 2                 # each run runs it again (no cache)
    f = start(fut)
    sleep(0.01)
    interrupt!(f)
    StreamHelpers.waitfor(f)
    @test isinterrupted(cause(f.exit)) && cancelled[] == 1
    @test run(zippar(succeed(1), succeed(2))) == (1, 2)
    @test run(race(andthen(_ -> succeed(:slow), delay(10)), succeed(:fast))) == :fast
end

@testitem "futures: collectpar keeps input order, bounds concurrency, fails fast" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: cause, isfail, failure
    @test run(collectpar(Effect[])) == Any[]
    # virtual time: 6 effects of decreasing length, 2 at a time
    active = Ref(0)
    peak = Ref(0)
    job(i) = andthen(_ -> andthen(_ -> sync(() -> (active[] -= 1; i)), delay(7 - i)), sync(() -> (active[] += 1; peak[] = max(peak[], active[]); nothing)))
    (v, c) = StreamHelpers.rt(andthen(r -> map(t -> (r, t), clocktime()), collectpar([job(i) for i in 1:6]; maxconcurrent = 2)))
    @test v[1] == 1:6
    @test peak[] == 2
    # slots: 1 (0-6), 2 (0-5); 3 (5-9), 4 (6-9); 5 (9-11), 6 (9-10)
    @test v[2] == 11.0
    @test StreamHelpers.settled(c) == 0
    # the first failure interrupts the rest
    rel = Ref(0)
    long = ensuring(delay(100), sync(() -> (rel[] += 1; nothing)))
    (x, _) = StreamHelpers.rt(catchcause(c -> succeed(c), map(_ -> nothing, collectpar([long, andthen(_ -> fail(:no), delay(1)), long]))))
    @test isfail(x) && failure(x) === :no
    @test rel[] == 2
    @test_throws ArgumentError collectpar([succeed(1)]; maxconcurrent = 0)
end
