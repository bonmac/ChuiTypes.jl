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
        wait(f)
        acq = [i for (k, i) in log if k === :acq]
        rel = [i for (k, i) in log if k === :rel]
        total = (n + 1) * steps
        ended_ok = killat > total ? succeeded(f.exit) : !succeeded(f.exit) && isinterrupted(cause(f.exit))
        return rel == reverse(acq) && allunique(rel) && ended_ok
    end
    function prop_finalizers(bracketfn = bracket)
        r = @check record = false db = false max_examples = MAX (
            n = Data.Integers(1, 5), steps = Data.Integers(0, 3), killat = Data.Integers(1, 25),
        ) -> finalizer_case(bracketfn, n, steps, killat)
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
        wait(f)
        acq, rel = @lock lk ([i for (k, i) in log if k === :acq], [i for (k, i) in log if k === :rel])
        return rel == reverse(acq) && allunique(rel)
    end
    function prop_realcancel(bracketfn = bracket)
        r = @check record = false db = false max_examples = 40 (
            n = Data.Integers(1, 4), micros = Data.Integers(0, 4000),
        ) -> realcancel_case(bracketfn, n, micros)
        return passed(r)
    end

    # ---- P3: a scope leaves no live fiber, whatever its children do --------------------------------
    # A random set of children (virtual delays, some failing) under a scope; after the run,
    # `livefibers()` is back where it started.
    function scope_case(forkfn, ds, failat)
        before = livefibers()
        child(i, d) = andthen(_ -> i == failat ? fail(:child) : succeed(i), delay(d))
        body = foldl((acc, (i, d)) -> andthen(_ -> map(_ -> nothing, forkfn(child(i, d))), acc), enumerate(ds); init = succeed(nothing))
        try
            runtest(scope(body))
        catch
        end
        return livefibers() == before
    end
    function prop_scopes(forkfn = fork)
        r = @check record = false db = false max_examples = MAX (
            ds = Data.Vectors(Data.Integers(0, 5); min_size = 0, max_size = 6), failat = Data.Integers(0, 6),
        ) -> scope_case(forkfn, ds, failat)
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
        else
            x = runexit(fromtaskfn(totask(sync(() -> throw(Cancelled())))))
            return isinterrupted(cause(x))
        end
    end
    function prop_roundtrip(fromtaskfn = fromtask)
        r = @check record = false db = false max_examples = MAX (
            kind = Data.Integers(0, 2), n = Data.Integers(-50, 50),
        ) -> roundtrip_case(fromtaskfn, kind, n)
        return passed(r)
    end
end

@testitem "property: finalizers run exactly once, LIFO, under cancellation at a random step" tags = [:property] setup = [EffectProps] begin
    @test EffectProps.prop_finalizers()
end

@testitem "property: finalizers under real-thread cancellation at a random time" tags = [:property] setup = [EffectProps] begin
    @test EffectProps.prop_realcancel()
end

@testitem "property: scopes leave no live fiber" tags = [:property] setup = [EffectProps] begin
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
    # a fork that escapes the scope (a root fiber nobody waits for)
    escaping_fork(e) = sync(() -> start(andthen(_ -> e, delay(0.05))))
    @test !EffectProps.prop_scopes(escaping_fork)
    # an adapter that keeps Base's wrapper instead of the original exception
    wrapping_fromtask(t) = async(
        cb -> (
            Threads.@spawn(
                cb(
                    try
                        Success(fetch(t))
                    catch ex
                        Failure(Fail(ex))
                    end
                )
            ); nothing
        )
    )
    @test !EffectProps.prop_roundtrip(wrapping_fromtask)
end
