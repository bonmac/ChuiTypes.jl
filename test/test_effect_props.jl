# Property tests for cancellation, resource safety, scopes and the Task round trip (ADR-0002
# Consequences, ADR-0006, ecosystem ADR-0013; spec §13). Every property runs as
# `@check record=false db=false ...` plus an explicit `@test` (ecosystem ADR-0007 §2 amendment).
# Each property is a function of the runtime operation it checks, so `test/laws/test_planted.jl`
# can run it against a deliberately wrong stand-in and assert that it fails (on 1.10 too).

@testmodule EffectProps begin
    using Test, Supposition
    using ChuiTypes
    using ChuiTypes: Success, cause, isinterrupted, succeeded, failure, livefibers

    const MAX = 100
    passed(r) = Supposition.results(r).ispass

    # ---- Bounded runtime --------------------------------------------------------------------------
    # Supposition 0.3 has no time limit, and its shrinker re-runs a failing case many times. Each
    # property gets a wall-clock budget: after it, every case throws `BudgetExceeded` at once, so
    # the property fails loudly (and shrinks instantly) instead of running for hours. Every wait on
    # a fiber is bounded too.
    const BUDGET = 120.0
    struct BudgetExceeded <: Exception
        name::String
    end
    Base.showerror(io::IO, b::BudgetExceeded) = print(io, "property `", b.name, "` exceeded its ", BUDGET, " s budget")
    function budgeted(name, case)
        deadline = time() + BUDGET
        return (args...) -> (time() > deadline && throw(BudgetExceeded(name)); case(args...))
    end
    "Wait for fiber `f` to end, or throw after `secs` seconds (a hang fails the case)."
    function waitfor(f::Fiber; secs = 20.0)
        t0 = time()
        while f.exit === nothing
            time() - t0 > secs && error("fiber did not end within $secs s")
            sleep(0.0005)
        end
        return f
    end

    # ---- P1: finalizers run exactly once, LIFO, under self-cancellation at a random step ----------
    # `n` nested brackets; each level's use runs `steps` sync steps before the next level. Step
    # number `killat` interrupts the fiber itself (test mode: the fiber does not run before
    # `start` returns, so its handle is known). Every acquired resource must be released exactly
    # once, in reverse order, and the run must end Interrupted iff the kill step was reached.
    function finalizer_case(bracketfn, n, steps, killat)
        log = Tuple{Symbol, Int}[]
        self = Ref{Any}(nothing)
        counter = Ref(0)
        step = sync(() -> (counter[] += 1; counter[] == killat && interrupt!(self[]); nothing))
        chain(k) = k == 0 ? succeed(nothing) : andthen(_ -> chain(k - 1), step)
        build(i) = i > n ? chain(steps) : bracketfn(
                sync(() -> (push!(log, (:acq, i)); i)),
                a -> andthen(_ -> build(i + 1), chain(steps)),
                (a, x) -> sync(() -> (push!(log, (:rel, a)); nothing)),
            )
        vc = VirtualClock()
        f = start(build(1); clock = vc)
        self[] = f
        waitfor(f)
        acq = [i for (k, i) in log if k === :acq]
        rel = [i for (k, i) in log if k === :rel]
        total = (n + 1) * steps
        ended_ok = killat > total ? succeeded(f.exit) : !succeeded(f.exit) && isinterrupted(cause(f.exit))
        return rel == reverse(acq) && allunique(rel) && ended_ok
    end
    function prop_finalizers(bracketfn = bracket)
        case = budgeted("finalizers", finalizer_case)
        r = @check record = false db = false max_examples = MAX (
            n = Data.Integers(1, 5), steps = Data.Integers(0, 3), killat = Data.Integers(1, 25),
        ) -> case(bracketfn, n, steps, killat)
        return passed(r)
    end

    # ---- P2: the same under real threads, cancelling from outside after a random delay ------------
    function realcancel_case(bracketfn, n, micros)
        log = Tuple{Symbol, Int}[]
        lk = ReentrantLock()
        build(i) = i > n ? delay(0.002) : bracketfn(
                sync(() -> (@lock lk push!(log, (:acq, i)); i)),
                a -> andthen(_ -> build(i + 1), delay(0.0005)),
                (a, x) -> sync(() -> (@lock lk push!(log, (:rel, a)); nothing)),
            )
        f = start(build(1))
        sleep(micros / 1.0e6)
        interrupt!(f)
        waitfor(f)
        acq, rel = @lock lk ([i for (k, i) in log if k === :acq], [i for (k, i) in log if k === :rel])
        return rel == reverse(acq) && allunique(rel)
    end
    function prop_realcancel(bracketfn = bracket)
        case = budgeted("realcancel", realcancel_case)
        r = @check record = false db = false max_examples = 40 (
            n = Data.Integers(1, 4), micros = Data.Integers(0, 4000),
        ) -> case(bracketfn, n, micros)
        return passed(r)
    end

    # ---- P3: scopes supervise and leave no live fiber ---------------------------------------------
    # A random set of children (virtual delays, at most one failing) under a scope. The scope fails
    # with the child's cause iff a child fails; then every sibling that had not finished was
    # cancelled (none finished normally); and the run's own clock counts no live or parked fiber.
    # (The process-wide `livefibers()` is not used here: fibers other test items leave running end
    # at unpredictable times, which made this property flaky and its shrinking endless.)
    function scope_case(forkfn, ds, failat)
        vc = VirtualClock()
        seen = Dict{Int, Symbol}()
        fin(i) = (_, x) -> sync(() -> (seen[i] = succeeded(x) ? :ok : :stopped; nothing))
        child(i, d) = bracket(succeed(i), _ -> andthen(_ -> i == failat ? fail(:child) : succeed(i), delay(d)), fin(i))
        body = foldl((acc, (i, d)) -> andthen(_ -> map(_ -> nothing, forkfn(child(i, d))), acc), enumerate(ds); init = succeed(nothing))
        x = runtest(map(_ -> :done, scope(body)) |> e -> catchfail(err -> succeed(err), e); clock = vc)
        clean = vc.live == 0 && vc.parked == 0
        fails = 1 <= failat <= length(ds)
        fails || return x === :done && clean
        dfail = ds[failat]
        later = [i for (i, d) in enumerate(ds) if d > dfail]   # still running when the child failed
        # a later sibling was stopped (its release saw a failure) or never acquired (forked into a
        # scope already cancelled): it never finished normally
        return x === :child && all(i -> get(seen, i, :none) !== :ok, later) && clean
    end
    function prop_scopes(forkfn = fork)
        case = budgeted("scopes", scope_case)
        r = @check record = false db = false max_examples = MAX (
            ds = Data.Vectors(Data.Integers(0, 5); min_size = 0, max_size = 6), failat = Data.Integers(0, 6),
        ) -> case(forkfn, ds, failat)
        return passed(r)
    end

    # ---- P4: the Task round trip keeps the value, the exception object and the cancellation ----------
    struct Boom <: Exception
        n::Int
    end
    function roundtrip_case(fromtaskfn, kind, n)
        if kind == 0
            return run(fromtaskfn(totask(succeed(n)))) == n
        elseif kind == 1
            ex = Boom(n)
            x = runexit(fromtaskfn(totask(die(ex))))
            return ChuiTypes.isfail(cause(x)) && failure(cause(x)) === ex
        elseif kind == 2
            x = runexit(fromtaskfn(totask(sync(() -> throw(Cancelled())))))
            return isinterrupted(cause(x))
        else
            # cancelling the adapter: ends Interrupted at once and counts the abandoned task
            # `t` is scheduled by the adapter's register step, which then parks at once; waiting
            # for `t` to start removes the race of interrupting before the adapter runs.
            gate, started = Base.Event(), Base.Event()
            t = @task (notify(started); wait(gate); n)
            o = ChuiTypes.orphans()
            f = start(fromtaskfn(t))
            wait(started)
            sleep(0.01)
            interrupt!(f)
            waitfor(f)
            ok = isinterrupted(cause(f.exit)) && ChuiTypes.orphans() == o + 1
            notify(gate)
            return ok && fetch(t) == n
        end
    end
    function prop_roundtrip(fromtaskfn = fromtask)
        case = budgeted("roundtrip", roundtrip_case)
        r = @check record = false db = false max_examples = MAX (
            kind = Data.Integers(0, 3), n = Data.Integers(-50, 50),
        ) -> case(fromtaskfn, kind, n)
        return passed(r)
    end

    # ---- P5: a release built from a combinator still runs under cancellation (masking) -------------
    # A bracket whose release is `comb(step)`, killed at a random step of its use (test mode,
    # self-interruption as in P1): the release's inner step must run exactly once.
    function maskedrelease_case(comb, steps, killat)
        hits = Ref(0)
        self = Ref{Any}(nothing)
        counter = Ref(0)
        step = sync(() -> (counter[] += 1; counter[] == killat && interrupt!(self[]); nothing))
        chain(k) = k == 0 ? succeed(nothing) : andthen(_ -> chain(k - 1), step)
        rel = (_, _) -> comb(sync(() -> (hits[] += 1; nothing)))
        f = start(bracket(succeed(1), _ -> chain(steps), rel); clock = VirtualClock())
        self[] = f
        waitfor(f)
        return hits[] == 1
    end
    const COMBS = Function[
        e -> timeout(e, 5),
        e -> map(first, zippar(e, succeed(1))),
        e -> race(e, delay(10)),
        e -> fromtask(() -> run(e)),
    ]
    function prop_maskedrelease(combs = COMBS)
        case = budgeted("maskedrelease", maskedrelease_case)
        r = @check record = false db = false max_examples = MAX (
            c = Data.Integers(1, length(combs)), steps = Data.Integers(1, 4), killat = Data.Integers(1, 5),
        ) -> case(combs[c], steps, killat)
        return passed(r)
    end
end

@testitem "property: finalizers run exactly once, LIFO, under cancellation at a random step" tags = [:property] setup = [EffectProps] begin
    @test EffectProps.prop_finalizers()
end

@testitem "property: finalizers under real-thread cancellation at a random time" tags = [:property] setup = [EffectProps] begin
    @test EffectProps.prop_realcancel()
end

@testitem "property: a release built from a combinator runs under cancellation" tags = [:property] setup = [EffectProps] begin
    @test EffectProps.prop_maskedrelease()
end

@testitem "property: scopes supervise and leave no live fiber" tags = [:property] setup = [EffectProps] begin
    @test EffectProps.prop_scopes()
end

@testitem "property: Task round trip keeps value, exception object and cancellation" tags = [:property] setup = [EffectProps] begin
    @test EffectProps.prop_roundtrip()
end

@testitem "planted: the effect properties fail on wrong stand-ins" tags = [:property, :laws] setup = [EffectProps] begin
    using ChuiTypes
    using ChuiTypes: Success, Failure, Fail
    # releases only after a successful use (no release on failure or interruption)
    leaky_bracket(acq, use, rel) = andthen(a -> andthen(r -> map(_ -> r, rel(a, Success(r))), use(a)), acq)
    @test !EffectProps.prop_finalizers(leaky_bracket)
    @test !EffectProps.prop_realcancel(leaky_bracket)
    # a fork that escapes the scope: a root fiber on the same virtual clock that nobody waits for
    # (it outlives the run, so the clock still counts it); the escapes are interrupted afterwards
    escaped = Fiber[]
    escaping_fork(e) = andthen(
        c -> sync(() -> (f = start(andthen(_ -> e, delay(10)); clock = c); push!(escaped, f); f)),
        service(ChuiTypes.AbstractClock),
    )
    @test !EffectProps.prop_scopes(escaping_fork)
    foreach(interrupt!, escaped)
    foreach(f -> EffectProps.waitfor(f), escaped)
    # a fork whose failure never reaches the scope (no supervision)
    unsupervised_fork(e) = fork(catchfail(_ -> succeed(nothing), e))
    @test !EffectProps.prop_scopes(unsupervised_fork)
    # an adapter that keeps Base's wrapper instead of the original exception (its canceller ends
    # it, so a cancelled run cannot hang the planted test)
    wrapping_fromtask(t) = async(
        cb -> begin
            Threads.@spawn(
                cb(
                    try
                        Success(fetch(t))
                    catch ex
                        Failure(Fail(ex))
                    end
                )
            )
            () -> cb(Failure(ChuiTypes.Interrupted()))
        end
    )
    @test !EffectProps.prop_roundtrip(wrapping_fromtask)
    # a combinator whose hidden child inherits the masked fiber's cancel state (reviewer B1)
    inheriting(e) = andthen(f -> andthen(ChuiTypes.fromexit, await(f)), fork(e))
    @test !EffectProps.prop_maskedrelease(Function[inheriting])
end
