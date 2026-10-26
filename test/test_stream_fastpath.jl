# The indexed `fromiter` source equals the generic iteration source (phase-5 spec D2, D3, R4):
# same elements, same chunk lengths, the same `eltype` of every chunk, the same failure. The
# property is a function of the source it checks, so the planted item can run it against wrong
# stand-ins (offset axes read from 1, undefined slots skipped, a snapshot at build, a narrowed
# element type) and assert that it fails.

@testmodule FastPath begin
    using Test, Supposition
    using ChuiTypes

    const MAX = 80
    passed(r) = Supposition.results(r).ispass

    "The generic path: iterate `x` element by element (what `fromiter` did before phase 5)."
    generic(x, n) = ChuiTypes._stream(eltype(x), ChuiTypes._IterSrc(x, n))
    fast(x, n) = fromiter(x; chunksize = n)

    "Inputs the indexed path takes (spec D2)."
    eligible(x) = x isa Vector || x isa AbstractRange ||
        (x isa SubArray && parent(x) isa Vector && IndexStyle(x) === IndexLinear())

    "A run's observable outcome: the chunks with their element types and lengths, or the exception type."
    function outcome(build)
        chunks = try
            run(runchunks(build()))
        catch e
            return (:failed, typeof(e))
        end
        return (:ok, Any[copy(c) for c in chunks], Any[eltype(c) for c in chunks], length.(chunks))
    end
    function same(a, b)
        a[1] === b[1] || return false
        a[1] === :failed && return a[2] === b[2]
        return isequal(a[2], b[2]) && a[3] == b[3] && a[4] == b[4]
    end

    "The case: `src(x, n)` gives what the generic path gives; with `checkpath`, `fromiter` takes the indexed path."
    function case(src, x, n; checkpath = true)
        if checkpath
            (fromiter(x).src isa ChuiTypes._IdxSrc) == eligible(x) || return false
        end
        return same(outcome(() -> src(x, n)), outcome(() -> generic(x, n)))
    end

    "A vector resized after the first pull (cold: each pull reads the vector as it is then)."
    function resized_case(src, xs, n, grow)
        run1(path) = begin
            v = copy(xs)
            try
                withbatches(path(v, n)) do it
                    out = Any[]
                    for (i, ch) in enumerate(it)
                        push!(out, (copy(ch), eltype(ch)))
                        i == 1 && (grow ? append!(v, 100:(100 + n + 2)) : resize!(v, max(0, length(v) - n - 1)))
                    end
                    out
                end
            catch e
                typeof(e)
            end
        end
        return isequal(run1(src), run1(generic))
    end

    function undef3()
        v = Vector{Any}(undef, 3)
        v[1] = 1
        v[3] = "c"
        return v
    end
    const FIXED = Any[
        Base.IdentityUnitRange(3:5), Vector{Any}(undef, 3), undef3(), Any[1, "a", 2.5], Any[1, 2, 3], Union{Int, Missing}[1, missing, 3],
        collect(1:10), 1:0, 1:10, 10:-3:-5, 0.0:0.25:2.0, LinRange(0, 1, 7), Base.OneTo(9), 'a':'k',
        view(collect(1:20), 3:17), view(collect(1:20), 2:3:20), view(Any[1, :b, "c", 4], 2:4),
        [[1], [2, 3]], String["x", "y", "z"], reshape(collect(1:6), 2, 3), Iterators.take(1:10, 7),
    ]
    function kindgen(k, a, b, s)
        lo, hi = minmax(a, b)
        k == 1 && return collect(lo:hi)
        k == 2 && return Any[isodd(i) ? i : string(i) for i in lo:hi]
        k == 3 && return Union{Int, Missing}[iseven(i) ? missing : i for i in lo:hi]
        k == 4 && return lo:hi
        k == 5 && return lo:s:hi
        k == 6 && return Base.IdentityUnitRange(lo:hi)
        k == 7 && return view(collect(1:41), (lo + 21):(hi + 21))
        k == 8 && return view(collect(1:41), (lo + 21):s:(hi + 21))
        k == 9 && return range(lo / 2, hi / 2; length = hi - lo + 1)
        return Base.OneTo(max(hi, 0))
    end
    function prop_fastpath(src = fast; checkpath = true)
        all(x -> all(n -> case(src, x, n; checkpath), (1, 2, 3, 1024)), FIXED) || return false
        all(c -> resized_case(src, collect(1:c[1]), c[2], c[3]), [(10, 3, true), (10, 3, false), (5, 2, true), (6, 4, false)]) || return false
        r = @check record = false db = false max_examples = MAX (
            k = Data.Integers(1, 10), a = Data.Integers(-20, 20), b = Data.Integers(-20, 20),
            s = Data.Integers(1, 4), n = Data.Integers(1, 7),
        ) -> case(src, kindgen(k, a, b, s), n; checkpath)
        passed(r) || return false
        r2 = @check record = false db = false max_examples = 30 (
            len = Data.Integers(0, 20), n = Data.Integers(1, 5), grow = Data.Booleans(),
        ) -> resized_case(src, collect(1:len), n, grow)
        return passed(r2)
    end

    # An iterator whose state type changes after the first element (Int, then Float64).
    struct Flip
        n::Int
    end
    Base.iterate(f::Flip) = f.n >= 1 ? (1, 1) : nothing
    Base.iterate(f::Flip, s) = s >= f.n ? nothing : (Int(s) + 1, Float64(s + 1))
    Base.IteratorSize(::Type{Flip}) = Base.SizeUnknown()
    Base.eltype(::Type{Flip}) = Int
end

@testitem "fromiter: indexed path for Vector, ranges and linear views only" tags = [:unit] setup = [FastPath] begin
    using ChuiTypes
    isidx(x) = fromiter(x).src isa ChuiTypes._IdxSrc
    @test isidx([1, 2, 3]) && isidx(Any[1, "a"]) && isidx(1:5) && isidx(0.0:0.5:2.0) && isidx(Base.IdentityUnitRange(3:5))
    @test isidx(view([1, 2, 3, 4], 2:3)) && isidx(view([1, 2, 3, 4], 1:2:4))
    @test !isidx(reshape(1:6, 2, 3)) && !isidx(collect(reshape(1:6, 2, 3))) && !isidx(Iterators.take(1:5, 3))
    @test !isidx(view(collect(reshape(1:6, 2, 3)), :, 1)) && !isidx((x for x in 1:3)) && !isidx(BitVector([1, 0]))
    # offset axes start at firstindex; undefined slots fail as iteration does
    @test run(runcollect(fromiter(Base.IdentityUnitRange(3:5); chunksize = 2))) == [3, 4, 5]
    @test_throws UndefRefError run(runcollect(fromiter(Vector{Any}(undef, 3))))
    @test eltype(run(runchunks(fromiter(Any[1, 2])))[1]) === Any
end

@testitem "fromiter: the generic source infers its state type, else Any" tags = [:unit] setup = [FastPath] begin
    using ChuiTypes
    ctx = ChuiTypes._Ctx(ChuiTypes._CancelState(), nothing, 0, nothing, nothing)
    statetype(x) = typeof(ChuiTypes._open(ChuiTypes._IterSrc(x, 4), ctx)).parameters[2]   # _IterP{I, S}
    @test isconcretetype(statetype(Iterators.take(collect(1:10), 7)))
    @test statetype(FastPath.Flip(5)) === Any                       # Int, then Float64: never concrete
    @test run(runcollect(fromiter(FastPath.Flip(9); chunksize = 4))) == collect(1:9)
    @test length.(run(runchunks(fromiter(FastPath.Flip(9); chunksize = 4)))) == [4, 4, 1]
    @test run(runcollect(fromiter(FastPath.Flip(0)))) == Int[]
end

@testitem "property: the indexed fromiter path equals the generic path" tags = [:property] setup = [FastPath] begin
    @test FastPath.prop_fastpath()
end

@testitem "planted: the fast-path property fails on wrong stand-ins" tags = [:property, :laws] setup = [FastPath] begin
    using ChuiTypes
    # reads offset axes from 1 (review B1)
    from1(x, n) = x isa AbstractVector ? fromiter([x[i] for i in 1:length(x)]; chunksize = n) : fromiter(x; chunksize = n)
    @test !FastPath.prop_fastpath(from1; checkpath = false)
    # skips undefined slots instead of failing (review B2)
    skipundef(x, n) = x isa Vector ? fromiter([x[i] for i in eachindex(x) if isassigned(x, i)]; chunksize = n) : fromiter(x; chunksize = n)
    @test !FastPath.prop_fastpath(skipundef; checkpath = false)
    # a snapshot at build time (not re-read per pull)
    snapshot(x, n) = fromiter(x isa Vector ? copy(x) : x; chunksize = n)
    @test !FastPath.prop_fastpath(snapshot; checkpath = false)
    # narrows the element type of the chunks
    narrowed(x, n) = fromiter(x isa AbstractVector ? map(identity, x) : x; chunksize = n)
    @test !FastPath.prop_fastpath(narrowed; checkpath = false)
end
