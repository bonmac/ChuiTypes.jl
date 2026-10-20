# Property tests for streams (ADR-0003; phase-4 spec §14). Every property runs as
# `@check record=false db=false ...` plus an explicit `@test`, has a wall-clock budget, and is a
# function of the operation it checks, so the planted item below can run it against a wrong
# stand-in and assert that it fails (on 1.10 too). Leak checks use per-test counters: the run's
# own VirtualClock (`live` back to 0) and local acquire/release counts, never `livefibers()`.

@testmodule StreamProps begin
    using Test, Supposition
    using ChuiTypes
    using ChuiTypes: succeeded, cause, isinterrupted, value, marbles, marbletrace

    const MAX = 60
    passed(r) = Supposition.results(r).ispass

    const BUDGET = 150.0
    struct BudgetExceeded <: Exception
        name::String
    end
    Base.showerror(io::IO, b::BudgetExceeded) = print(io, "property `", b.name, "` exceeded its ", BUDGET, " s budget")
    function budgeted(name, case)
        deadline = time() + BUDGET
        return (args...) -> (time() > deadline && throw(BudgetExceeded(name)); case(args...))
    end
    function settled(c::VirtualClock; secs = 10.0)
        t0 = time()
        while (@lock c.lock c.live) != 0 && time() - t0 < secs
            sleep(0.0005)
        end
        return @lock c.lock c.live
    end

    # ---- S1: fused pipelines equal the list model, at any chunk size ------------------------------
    # An op is (kind, parameter). The model applies the same ops to a plain vector.
    const OPS = (:map, :filter, :scan, :take, :drop, :takewhile, :buffer)
    function model(op, p, xs)
        op === :map && return xs .* p .+ 1
        op === :filter && return filter(x -> mod(x, p + 1) != 0, xs)
        op === :scan && return accumulate(+, xs; init = p)
        op === :take && return xs[1:min(p, end)]
        op === :drop && return xs[(min(p, length(xs)) + 1):end]
        op === :takewhile && return (i = findfirst(x -> x > p * 10, xs); i === nothing ? xs : xs[1:(i - 1)])
        op === :buffer && return [sum(xs[i:min(i + p, end)]) for i in 1:(p + 1):length(xs)]
    end
    function apply(op, p, s, scanfn, takefn)
        op === :map && return map(x -> x * p + 1, s)
        op === :filter && return filter(x -> mod(x, p + 1) != 0, s)
        op === :scan && return scanfn(+, p, s)
        op === :take && return takefn(s, p)
        op === :drop && return Iterators.drop(s, p)
        op === :takewhile && return Iterators.takewhile(x -> !(x > p * 10), s)
        op === :buffer && return map(sum, buffer(s, p + 1))
    end
    function fusion_case(scanfn, takefn, xs, chunk, ops)
        s = fromiter(xs; chunksize = chunk)
        ys = collect(xs)
        for (op, p) in ops
            s = apply(op, p, s, scanfn, takefn)
            ys = model(op, p, ys)
        end
        return isequal(run(runcollect(s)), ys)
    end
    # Fixed cases run before the random ones, so a wrong stand-in is caught deterministically
    # (random generation alone missed the planted scan/take in 1 of 3 runs).
    const FIXED_FUSION = [
        (collect(1:20), 3, [(:scan, 1)]), (collect(1:20), 3, [(:take, 5)]),
        (collect(-9:9), 4, [(:drop, 6), (:buffer, 2)]), (collect(1:30), 7, [(:takewhile, 2), (:map, 3)]),
        (collect(1:25), 2, [(:filter, 2), (:scan, 4), (:take, 6)]),
    ]
    function prop_fusion(scanfn = scan, takefn = Iterators.take)
        all(c -> fusion_case(scanfn, takefn, c...), FIXED_FUSION) || return false
        case = budgeted("fusion", fusion_case)
        opgen = Data.Vectors(map(t -> (OPS[t[1]], t[2]), Data.Pairs(Data.Integers(1, length(OPS)), Data.Integers(1, 6))); max_size = 4)
        r = @check record = false db = false max_examples = MAX (
            xs = Data.Vectors(Data.Integers(-50, 50); max_size = 40), chunk = Data.Integers(1, 7), ops = opgen,
        ) -> case(scanfn, takefn, xs, chunk, ops)
        return passed(r)
    end

    # ---- S2: interrupted at a random virtual time, a concurrent tree leaves no live fiber and ----
    # releases every resource it acquired exactly once.
    function tree(kind, depth, n, res)
        leaf = res(Iterators.take(interval(0.5 + 0.25 * mod(n, 3)), 3 + mod(n, 4)))
        depth == 0 && return leaf
        sub = tree(mod(kind + n, 6), depth - 1, n + 1, res)
        kind == 0 && return merge(leaf, sub)
        kind == 1 && return mergemap(_ -> sub, Iterators.take(interval(1.0), 3); maxconcurrent = 2)
        kind == 2 && return switchmap(_ -> sub, Iterators.take(interval(1.5), 3))
        kind == 3 && return concatmap(_ -> sub, fromiter(1:2))
        kind == 4 && return debounce(merge(leaf, sub), 0.3)
        return prefetch(buffertime(merge(leaf, sub), 1.0))
    end
    function cancel_case(bracketfn, kind, depth, killat)
        acq = Ref(0)
        rel = Ref(0)
        res(s) = concatmap(_ -> s, bracketfn(sync(() -> (acq[] += 1; nothing)), (a, x) -> sync(() -> (rel[] += 1; nothing))))
        s = tree(kind, depth, kind, res)
        prog = andthen(fork(runcollect(s))) do f
            andthen(_ -> (interrupt!(f); await(f)), delay(killat))
        end
        c = VirtualClock()
        x = runtest(prog; clock = c)
        ok_exit = succeeded(x) || isinterrupted(cause(x))
        return settled(c) == 0 && acq[] == rel[] && ok_exit
    end
    function prop_cancel(bracketfn = bracketstream)
        all(c -> cancel_case(bracketfn, c...), [(0, 1, 1.0), (1, 2, 2.5), (2, 2, 3.0), (5, 3, 1.75)]) || return false
        case = budgeted("cancel", cancel_case)
        r = @check record = false db = false max_examples = MAX (
            kind = Data.Integers(0, 5), depth = Data.Integers(0, 3), killat = map(k -> k / 4, Data.Integers(0, 40)),
        ) -> case(bracketfn, kind, depth, killat)
        return passed(r)
    end

    # ---- S3: a cold marble source traced on virtual time gives back its spec ---------------------
    const MCH = ('-', 'a', 'b', 'c')
    function spec_of(body, groups, term)
        s = join(MCH[i] for i in body)
        for (pos, g) in groups
            pos <= length(s) || continue
            s = s[1:(pos - 1)] * "(" * join(MCH[i + 1] for i in g) * ")" * s[(pos + 1):end]
        end
        return s * (term == 0 ? "" : term == 1 ? "|" : "#")
    end
    function roundtrip_case(source, body, groups, term)
        spec = spec_of(body, groups, term)
        frames = length(replace(spec, r"\([^)]*\)" => "X"))      # a group is one frame
        c = VirtualClock()
        out = runtest(marbletrace(source(spec); frames); clock = c)
        return out == spec && settled(c) == 0
    end
    function prop_roundtrip(source = marbles)
        all(c -> roundtrip_case(source, c...), [([2, 1, 3], [], 1), ([1, 2], [(2, [1, 2])], 2), ([2, 2], [], 0)]) || return false
        case = budgeted("roundtrip", roundtrip_case)
        r = @check record = false db = false max_examples = MAX (
            body = Data.Vectors(Data.Integers(1, 4); min_size = 1, max_size = 8),
            groups = Data.Vectors(Data.Pairs(Data.Integers(1, 8), Data.Vectors(Data.Integers(1, 3); min_size = 2, max_size = 3)); max_size = 1),
            term = Data.Integers(0, 2),
        ) -> case(source, body, groups, term)
        return passed(r)
    end

    # ---- S4: a Queue delivers every offered item exactly once, in each producer's order ----------
    function queue_case(offerfn, cap, nprod, nitems, delays)
        q = Queue{Tuple{Int, Int}}(cap)
        producer(p) = foldl(1:nitems; init = succeed(nothing)) do acc, i
            andthen(_ -> andthen(_ -> offerfn(q, (p, i)), delay(delays[mod1(p + i, length(delays))])), acc)
        end
        got = Tuple{Int, Int}[]
        consumer = foldl(1:(nprod * nitems); init = succeed(nothing)) do acc, i
            andthen(_ -> andthen(x -> sync(() -> (push!(got, x); nothing)), receive(q)), acc)
        end
        forks = foldl((acc, p) -> andthen(_ -> map(_ -> nothing, fork(producer(p))), acc), 1:nprod; init = succeed(nothing))
        prog = andthen(_ -> consumer, forks)
        c = VirtualClock()
        ok = try
            runtest(timeout(prog, 10.0^4); clock = c) == some(nothing)
        catch
            false
        end
        ok || return false
        return all(p -> [i for (q, i) in got if q == p] == 1:nitems, 1:nprod) && settled(c) == 0
    end
    function prop_queue(offerfn = offer)
        all(c -> queue_case(offerfn, c...), [(1, 2, 4, [0.0]), (2, 3, 5, [0.5, 0.0])]) || return false
        case = budgeted("queue", queue_case)
        r = @check record = false db = false max_examples = MAX (
            cap = Data.Integers(1, 3), nprod = Data.Integers(1, 3), nitems = Data.Integers(1, 6),
            delays = Data.Vectors(map(k -> k / 2, Data.Integers(0, 3)); min_size = 1, max_size = 4),
        ) -> case(offerfn, cap, nprod, nitems, delays)
        return passed(r)
    end
end

@testitem "property: fused pipelines equal the list model at any chunk size" tags = [:property] setup = [StreamProps] begin
    @test StreamProps.prop_fusion()
end

@testitem "property: interrupted concurrent streams leave no live fiber and release once" tags = [:property] setup = [StreamProps] begin
    @test StreamProps.prop_cancel()
end

@testitem "property: marble source and trace round-trip" tags = [:property] setup = [StreamProps] begin
    @test StreamProps.prop_roundtrip()
end

@testitem "property: Queue delivers exactly once, in order per producer" tags = [:property] setup = [StreamProps] begin
    @test StreamProps.prop_queue()
end

@testitem "planted: the stream properties fail on wrong stand-ins" tags = [:property, :laws] setup = [StreamProps] begin
    using ChuiTypes
    # a scan that forgets its state between elements, and a take that restarts per chunk
    forgetful_scan(op, init, s) = concatmap(x -> fromiter([op(init, x)]), s)
    @test !StreamProps.prop_fusion(forgetful_scan)
    chunk_take(s, n) = concatmap(c -> fromiter(c[1:min(n, end)]), map(identity, buffer(s, 2)))
    @test !StreamProps.prop_fusion(scan, chunk_take)
    # a bracketstream that releases only when its stream ends normally (not on interruption)
    leaky_bracketstream(acq, rel) = concat(fromeffect(acq), concatmap(_ -> emptystream(Nothing), fromeffect(rel(nothing, ChuiTypes.Success(nothing)))))
    @test !StreamProps.prop_cancel(leaky_bracketstream)
    # a source that ignores time (an untimed list of the elements)
    untimed(spec) = fromiter(collect(filter(c -> c in "abc", spec)))
    @test !StreamProps.prop_roundtrip(untimed)
    # an offer that drops the item when the queue is full instead of waiting
    dropping_offer(q, x) = sync(() -> (ChuiTypes._tryput!(q, x); nothing))
    @test !StreamProps.prop_queue(dropping_offer)
end
