# Unit tests for the effect runtime (ADR-0002, ADR-0006; spec 2026-10-20-phase3-effects-design.md).

@testitem "Effect: values, run, runexit, outcomes" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: Success, Failure, Fail, Die, Interrupted, isfail, isdie, isinterrupted, cause, value, succeeded
    @test run(succeed(1)) === 1
    @test run(succeed(1), Int) === 1
    @test_throws TypeError run(succeed(1), String)
    @test succeed(1) isa Effect{Union{}, Int}
    @test fail("e") isa Effect{String, Union{}}
    @test runexit(succeed(2)) == Success(2)
    @test runexit(fail("e")) == Failure(Fail("e"))
    @test Success(1) isa Exit{Union{}, Int}
    @test value(Success(3)) == 3
    @test_throws ArgumentError value(Failure(Fail(1)))
    @test_throws ArgumentError cause(Success(1))
    @test isfail(cause(runexit(fail(1))))
    # Fail(e::Exception) throws e itself; a non-exception throws EffectFailed(e)
    err = ErrorException("boom")
    @test (
        try
            run(fail(err))
        catch ex
            ex
        end
    ) === err
    @test (
        try
            run(fail(:nope))
        catch ex
            ex
        end
    ) == EffectFailed(:nope)
    # a throw inside sync is a Die and run rethrows the same object
    @test isdie(cause(runexit(sync(() -> throw(err)))))
    @test (
        try
            run(sync(() -> throw(err)))
        catch ex
            ex
        end
    ) === err
    @test (
        try
            run(die(err))
        catch ex
            ex
        end
    ) === err
    @test isinterrupted(Interrupted())
    @test sprint(show, Success(1)) == "Success(1)"
    @test sprint(show, Failure(Fail("e"))) == "Failure(Fail(\"e\"))"
    @test sprint(show, Die(err)) == "Die(ErrorException(\"boom\"))"
    @test Fail(1) == Fail(1) && Fail(1) != Fail(2) && Fail(1) != Die(1)
    @test isequal(Success([1]), Success([1])) && hash(Success([1])) == hash(Success([1]))
    @test succeeded(Success(nothing)) && !succeeded(Failure(Interrupted()))
end

@testitem "Effect: map, andthen, defer, stack safety" tags = [:unit] begin
    using ChuiTypes
    @test run(map(x -> x * 2, succeed(21))) == 42
    @test run(andthen(x -> succeed(x + 1), succeed(1))) == 2
    @test run(andthen(x -> fail(x), succeed(1)) |> e -> catchfail(succeed, e)) == 1
    # a continuation that returns a non-effect is a defect naming the problem
    x = runexit(andthen(x -> x + 1, succeed(1)))
    @test ChuiTypes.isdie(ChuiTypes.cause(x)) && ChuiTypes.failure(ChuiTypes.cause(x)) isa ArgumentError
    # left- and right-nested binds, 10^5 deep
    n = 100_000
    function leftnested(n)
        m = succeed(0)
        for _ in 1:n
            m = andthen(x -> succeed(x + 1), m)
        end
        return m
    end
    @test run(leftnested(n)) == n
    count(i) = i == 0 ? succeed(:done) : andthen(_ -> count(i - 1), succeed(i))
    @test run(count(n)) === :done
    loop(i) = i == 0 ? succeed(0) : defer(() -> map(x -> x + 1, loop(i - 1)))
    @test run(loop(n)) == n
    # effects are values: running one twice runs it twice
    hits = Ref(0)
    e = sync(() -> hits[] += 1)
    run(e)
    run(e)
    @test hits[] == 2
end

@testitem "Effect: errors" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: Fail, Die, isdie, cause, failure
    err = ErrorException("x")
    @test run(catchfail(e -> succeed(e * "!"), fail("e"))) == "e!"
    # catchfail does not see defects; catchcause does
    @test isdie(cause(runexit(catchfail(_ -> succeed(0), die(err)))))
    @test run(catchcause(c -> succeed(failure(c)), die(err))) === err
    @test run(catchcause(c -> succeed(failure(c)), fail(1))) == 1
    @test runexit(mapfail(e -> e + 1, fail(1))) == ChuiTypes.Failure(Fail(2))
    # attempt: a throw is a Fail, EffectFailed and Cancelled are unwrapped
    @test runexit(attempt(() -> throw(err))) == ChuiTypes.Failure(Fail(err))
    @test runexit(attempt(() -> throw(EffectFailed(:k)))) == ChuiTypes.Failure(Fail(:k))
    @test ChuiTypes.isinterrupted(cause(runexit(attempt(() -> throw(Cancelled())))))
    @test run(catchfail(e -> succeed(e), attempt(() -> throw(err)))) === err
    # a handler that throws is a defect
    @test isdie(cause(runexit(catchfail(_ -> error("h"), fail(1)))))
end

@testitem "Effect: environment and services" tags = [:unit] begin
    using ChuiTypes
    struct Config
        n::Int
    end
    @test run(provide(service(Config), Config(3))).n == 3
    # innermost wins; abstract lookup
    e = provide(provide(map(c -> c.n, service(Config)), Config(2)), Config(1))
    @test run(e) == 2
    @test run(provide(service(Integer), 5)) == 5
    x = runexit(service(Config))
    @test ChuiTypes.failure(ChuiTypes.cause(x)) == MissingService(Config)
    @test run(service(ChuiTypes.AbstractClock)) === ChuiTypes.RealClock()
    @test startswith(sprint(showerror, MissingService(Int)), "MissingService: no service of type Int64")
    # forks inherit the environment
    e2 = andthen(f -> andthen(fromexit_ -> ChuiTypes.fromexit(fromexit_), await(f)), fork(map(c -> c.n, service(Config))))
    @test run(provide(e2, Config(7))) == 7
end

@testitem "Effect: nested run inside sync shares the fiber" tags = [:unit] begin
    using ChuiTypes
    struct Tok
        s::String
    end
    inner = sync(() -> run(map(t -> t.s, service(Tok))))
    @test run(provide(inner, Tok("hi"))) == "hi"
end

@testitem "Effect: cancellation, masking, checkcancel" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: isinterrupted, cause
    # a fiber cancelled while parked in delay ends Interrupted
    f = start(delay(60))
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test isinterrupted(cause(f.exit))
    @test (
        try
            fetch(f)
        catch ex
            ex
        end
    ) isa Cancelled
    # uninterruptible: the cancel takes effect after the masked region
    log = Int[]
    body = andthen(_ -> sync(() -> push!(log, 2)), uninterruptible(andthen(_ -> sync(() -> push!(log, 1)), delay(0.2))))
    f = start(body)
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test log == [1]
    @test isinterrupted(cause(f.exit))
    # interruptiblemask: restore makes the inner part cancellable again
    f = start(interruptiblemask(restore -> restore(delay(60))))
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test isinterrupted(cause(f.exit))
    # checkcancel inside a sync stops cooperative work
    spins = Threads.Atomic{Int}(0)
    work = sync(
        () -> while true
            checkcancel()
            Threads.atomic_add!(spins, 1)
            sleep(0.001)
        end
    )
    f = start(work)
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test isinterrupted(cause(f.exit))
    @test spins[] > 0
    @test checkcancel() === nothing      # outside the runtime it does nothing
end

@testitem "Effect: fork, await, scopes and supervision" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: Success, Fail, isinterrupted, isfail, cause, fromexit
    # await gives the child's Exit
    e = andthen(f -> await(f), fork(succeed(5)))
    @test run(e) == Success(5)
    # a scope waits for its children
    done = Threads.Atomic{Bool}(false)
    e = andthen(_ -> succeed(:body), fork(andthen(_ -> sync(() -> (done[] = true)), delay(0.05))))
    @test run(e) === :body
    @test done[]
    # the first child failure cancels the siblings and the body, and fails the scope
    sib = Ref(:running)
    prog = andthen(
        _ -> andthen(_ -> delay(60), fork(fail(:child))),
        fork(ensuring(delay(60), sync(() -> (sib[] = :released)))),
    )
    x = runexit(prog)
    @test x == ChuiTypes.Failure(Fail(:child))
    @test sib[] === :released
    # an interrupted child does not fail the scope
    prog2 = andthen(f -> andthen(_ -> succeed(:ok), sync(() -> interrupt!(f))), fork(delay(60)))
    @test run(prog2) === :ok
    # cancelling a parent cancels its children
    child_exit = Ref{Any}(nothing)
    parent = andthen(f -> andthen(_ -> delay(60), succeed(nothing)), fork(ensuring(delay(60), sync(() -> (child_exit[] = :fin)))))
    f = start(parent)
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test isinterrupted(cause(f.exit))
    @test child_exit[] === :fin
    # scope(...) narrows the region: the outer code runs after the inner scope's children end
    order = String[]
    inner = scope(andthen(_ -> sync(() -> push!(order, "body")), fork(andthen(_ -> sync(() -> push!(order, "child")), delay(0.05)))))
    @test (run(andthen(_ -> sync(() -> push!(order, "after")), inner)); order == ["body", "child", "after"])
end

@testitem "Effect: bracket, acquirerelease, ensuring" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: Fail, isfail, isinterrupted, cause, suppressed, failure
    log = String[]
    rel(name) = (a, x) -> sync(() -> push!(log, "release $name $(ChuiTypes.succeeded(x))"))
    acq(name) = sync(() -> (push!(log, "acquire $name"); name))
    e = bracket(acq("a"), a -> bracket(acq("b"), b -> sync(() -> push!(log, "use $a$b")), rel("b")), rel("a"))
    run(e)
    @test log == ["acquire a", "acquire b", "use ab", "release b true", "release a true"]
    # release runs on failure, with the failure's Exit, and the failure stands
    empty!(log)
    x = runexit(bracket(acq("a"), _ -> fail(:u), rel("a")))
    @test log == ["acquire a", "release a false"]
    @test failure(cause(x)) === :u
    # a failing release after a failed use is suppressed; every release runs
    empty!(log)
    x = runexit(bracket(acq("a"), _ -> bracket(acq("b"), _ -> fail(:u), (_, _) -> fail(:rb)), rel("a")))
    @test failure(cause(x)) === :u
    @test failure.(suppressed(cause(x))) == [:rb]
    @test log == ["acquire a", "acquire b", "release a false"]
    # a failing release fails a successful bracket
    @test failure(cause(runexit(bracket(succeed(1), succeed, (_, _) -> fail(:r))))) === :r
    # acquire failure: no release
    empty!(log)
    x = runexit(bracket(fail(:acq), _ -> succeed(1), rel("never")))
    @test isempty(log) && failure(cause(x)) === :acq
    # acquirerelease releases at scope end, LIFO
    empty!(log)
    prog = scope(
        andthen(
            a -> andthen(b -> sync(() -> push!(log, "use $a$b")), acquirerelease(acq("y"), rel("y"))),
            acquirerelease(acq("x"), rel("x")),
        )
    )
    run(prog)
    @test log == ["acquire x", "acquire y", "use xy", "release y true", "release x true"]
    # release runs on interruption
    empty!(log)
    f = start(bracket(acq("a"), _ -> delay(60), rel("a")))
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test log == ["acquire a", "release a false"]
    @test isinterrupted(cause(f.exit))
    # ensuring
    hit = Ref(0)
    runexit(ensuring(fail(1), sync(() -> (hit[] += 1))))
    run(ensuring(succeed(1), sync(() -> (hit[] += 1))))
    @test hit[] == 2
end

@testitem "Effect: race, racefirst, zippar, timeout" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: Fail, cause, failure, suppressed
    @test run(race(andthen(_ -> succeed(:slow), delay(0.3)), andthen(_ -> succeed(:fast), delay(0.01)))) === :fast
    @test run(race(fail(:a), andthen(_ -> succeed(:b), delay(0.01)))) === :b
    x = runexit(race(fail(:a), andthen(_ -> fail(:b), delay(0.01))))
    @test failure(cause(x)) === :a && failure.(suppressed(cause(x))) == [:b]
    @test failure(cause(runexit(racefirst(fail(:a), andthen(_ -> succeed(:b), delay(0.2)))))) === :a
    @test run(zippar(succeed(1), andthen(_ -> succeed(2), delay(0.01)))) == (1, 2)
    @test failure(cause(runexit(zippar(andthen(_ -> fail(:x), delay(0.01)), delay(60))))) === :x
    # the loser is interrupted and awaited: its finalizer has run when the race returns
    fin = Ref(false)
    r = run(race(ensuring(delay(60), sync(() -> (fin[] = true))), succeed(:w)))
    @test r === :w && fin[]
    @test run(timeout(andthen(_ -> succeed(1), delay(0.01)), 5)) == some(1)
    @test run(timeout(delay(60), 0.05)) == none(Nothing)
    @test failure(cause(runexit(timeoutfail(delay(60), 0.05, :late)))) === :late
    @test run(timeoutfail(succeed(3), 5, :late)) == 3
end

@testitem "Effect: clocks and test mode" tags = [:unit] begin
    using ChuiTypes
    t = run(clocktime())
    @test abs(t - time()) < 5
    # runtest jumps virtual time: an hour of delays runs at once
    vc = VirtualClock()
    @test runtest(andthen(_ -> clocktime(), delay(3600)); clock = vc) == 3600.0
    # same-instant wake-ups run in scheduling order, every time
    function prog()
        log = Int[]
        w(i) = andthen(_ -> sync(() -> push!(log, i)), delay(1))
        e = andthen(_ -> succeed(log), andthen(_ -> andthen(_ -> fork(w(3)), fork(w(2))), fork(w(1))))
        return e
    end
    orders = Set{Vector{Int}}()
    for _ in 1:50
        push!(orders, runtest(prog()))
    end
    @test orders == Set([[1, 2, 3]])
    # advance! drives a started test-mode fiber step by step
    vc = VirtualClock()
    seen = Float64[]
    ticker = andthen(_ -> andthen(_ -> andthen(t -> sync(() -> push!(seen, t)), clocktime()), delay(5)), andthen(t -> sync(() -> push!(seen, t)), andthen(_ -> clocktime(), delay(2))))
    f = start(ticker; clock = vc)
    advance!(vc, 1)
    @test isempty(seen)
    advance!(vc, 1)
    @test seen == [2.0]
    advance!(vc, 10)
    @test seen == [2.0, 7.0]
    wait(f)
    # timeout and retry on virtual time
    @test runtest(timeout(delay(10), 3)) == none(Nothing)
    @test runtest(timeout(andthen(_ -> succeed(:ok), delay(2)), 3)) == some(:ok)
    tries = Ref(0)
    flaky = andthen(_ -> tries[] < 3 ? fail(:again) : succeed(tries[]), sync(() -> (tries[] += 1)))
    vc = VirtualClock()
    @test runtest(andthen(n -> map(t -> (n, t), clocktime()), retry(flaky, recurs(5, spaced(10)))); clock = vc) == (3, 20.0)
    tries[] = -100
    @test ChuiTypes.failure(ChuiTypes.cause(ChuiTypes.runexit(provide(retry(flaky, recurs(2)), VirtualClock())))) === :again
    # a deadlock is reported
    @test_throws ErrorException runtest(andthen(f -> await(f), fork(async(cb -> nothing))); timeout = 0.2)
end

@testitem "Effect: schedules" tags = [:unit] begin
    using ChuiTypes
    @test recurs(2).next.(1:3) == [0.0, 0.0, nothing]
    @test spaced(1.5).next(100) == 1.5
    @test exponential(1).next.(1:4) == [1.0, 2.0, 4.0, 8.0]
    @test exponential(1; factor = 3).next(3) == 9.0
    @test recurs(2, exponential(1)).next.(1:3) == [1.0, 2.0, nothing]
    # Die is not retried
    n = Ref(0)
    x = runexit(retry(andthen(_ -> die(ErrorException("d")), sync(() -> n[] += 1)), recurs(5)))
    @test ChuiTypes.isdie(ChuiTypes.cause(x)) && n[] == 1
end

@testitem "Effect: async canceller protocol" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: Success, Failure, Fail, cause, isinterrupted, failure
    # cb called later from another task
    e = async(
        cb -> (
            Threads.@spawn(
                begin
                    sleep(0.01); cb(Success(4))
                end
            ); nothing
        )
    )
    @test run(e) == 4
    # cb called before register returns; later calls ignored
    @test run(async(cb -> (cb(Success(1)); cb(Success(2)); nothing))) == 1
    @test failure(cause(runexit(async(cb -> (cb(Failure(Fail(:e))); nothing))))) === :e
    # a non-Exit is a defect
    @test ChuiTypes.isdie(cause(runexit(async(cb -> (cb(3); nothing)))))
    # cancellation calls the canceller, then waits for cb
    called = Threads.Atomic{Bool}(false)
    e = async(cb -> () -> (called[] = true; cb(Success(:late))))
    f = start(e)
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test called[] && isinterrupted(cause(f.exit))
    # grace: a canceller that never calls cb gives up and counts an orphan
    o = ChuiTypes.orphans()
    f = start(async((cb -> () -> nothing); grace = 0.05))
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test isinterrupted(cause(f.exit))
    @test ChuiTypes.orphans() == o + 1
end

@testitem "Effect: Task adapters (ADR-0006, ecosystem ADR-0013)" tags = [:unit] begin
    using ChuiTypes
    using ChuiTypes: Success, Failure, Fail, cause, isfail, isinterrupted, failure
    # Task -> effect: success, and failure keeps the task's own exception object
    t = @task 1 + 1
    @test run(fromtask(t)) == 2
    @test run(fromtask(t)) == 2         # runs once, later runs see the same outcome
    err = ErrorException("task failed")
    tf = Threads.@spawn throw(err)
    x = runexit(fromtask(tf))
    @test isfail(cause(x)) && failure(cause(x)) === err
    @test (
        try
            run(fromtask(tf))
        catch ex
            ex
        end
    ) === err
    @test (
        try
            fetch(start(fromtask(tf)))
        catch ex
            ex
        end
    ) === err
    # cancellation without a canceller abandons the task and counts an orphan
    o = ChuiTypes.orphans()
    gate = Base.Event()
    slow = Threads.@spawn (wait(gate); :done)
    f = start(fromtask(slow))
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test isinterrupted(cause(f.exit))
    @test ChuiTypes.orphans() == o + 1
    notify(gate)
    @test fetch(slow) === :done
    # with a canceller: it runs, then the effect awaits the task
    gate2 = Base.Event()
    slow2 = Threads.@spawn (wait(gate2); :stopped)
    f = start(fromtask(slow2; canceller = () -> notify(gate2)))
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test isinterrupted(cause(f.exit)) && istaskdone(slow2)
    # fromtask(f::Function): cooperative work sees the fiber's cancellation
    stopped = Threads.Atomic{Bool}(false)
    work = fromtask(
        () -> try
            while true
                checkcancel()
                sleep(0.001)
            end
        finally
            stopped[] = true
        end
    )
    f = start(work)
    sleep(0.05)
    interrupt!(f)
    wait(f)
    @test isinterrupted(cause(f.exit)) && stopped[]
    @test run(fromtask(() -> 41 + 1)) == 42
    @test failure(cause(runexit(fromtask(() -> throw(err))))) === err
    # Effect -> Task: fetch wraps, task.exception is the original object
    @test fetch(totask(succeed(9))) == 9
    tt = totask(fail(err))
    ex = try
        fetch(tt)
    catch e
        e
    end
    @test ex isa TaskFailedException && ex.task.exception === err
    # round trip: Die comes back as Fail, the object is kept
    x = runexit(fromtask(totask(die(err))))
    @test isfail(cause(x)) && failure(cause(x)) === err
    @test isinterrupted(cause(runexit(fromtask(totask(sync(() -> throw(Cancelled())))))))
end
