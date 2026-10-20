# The bounded Source path (R10; ADR-0008, Accepted; phase-4 spec §10). A mock of ChuiFrames'
# CF-011 Source built only from ChuiTypes' public stream API (no ChuiFrames dependency).

@testitem "Source path: snapshot at construction, schema from eltype, stable plans" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    # The mock adapter: what ChuiFrames' stream source would do (ADR-0008 §1-§4).
    struct MockSource{T}
        parts::Vector{Vector{T}}
        names::Tuple
        types::Tuple
    end
    function mocksource(s::Stream; maxelements = 10^6)
        T = eltype(s)
        parts = run(runchunks(s; maxelements))
        if isconcretetype(T) && T <: NamedTuple
            names, types = fieldnames(T), Tuple(fieldtypes(T))
        else
            isempty(parts) && throw(ArgumentError("empty stream with a non-concrete eltype needs a schema"))
            E = mapreduce(typeof, typejoin, reduce(vcat, parts))
            names, types = fieldnames(E), Tuple(fieldtypes(E))
        end
        return MockSource{T}(parts, names, types)
    end
    plan(src::MockSource) = collect(eachindex(src.parts))            # the partition handles
    readpart(src::MockSource, p) = src.parts[p]                         # a row table
    rows = map(i -> (x = i, y = Float64(i)), fromiter(1:2500))
    @test eltype(rows) == NamedTuple{(:x, :y), Tuple{Int, Float64}}
    src = mocksource(rows)
    @test (src.names, src.types) == ((:x, :y), (Int, Float64))
    @test plan(src) == plan(src) == [1, 2, 3]                            # explain, then collect
    @test readpart(src, 2) === readpart(src, 2)                         # re-readable, immutable
    @test sum(p -> length(readpart(src, p)), plan(src)) == 2500
    # partitions read on several threads give the same rows (thread-safe snapshot)
    tot = Threads.Atomic{Int}(0)
    @sync for p in plan(src)
        Threads.@spawn Threads.atomic_add!(tot, sum(r -> r.x, readpart(src, p)))
    end
    @test tot[] == sum(1:2500)
    # a concurrent stream: the snapshot fixes one interleaving; later plans agree with it
    m = merge(map(i -> (x = i, y = 0.0), fromiter(1:3000)), map(i -> (x = -i, y = 0.0), fromiter(1:3000)))
    msrc = StreamHelpers.bounded(() -> mocksource(m), "merge snapshot")
    @test plan(msrc) == plan(msrc)
    @test sort([r.x for p in plan(msrc) for r in readpart(msrc, p)]) == sort(vcat(1:3000, -(1:3000)))
    # an unbounded stream fails at the bound instead of exhausting memory
    inf = map(i -> (x = i, y = 0.0), fromiter(Iterators.countfrom(1)))
    @test_throws ArgumentError mocksource(inf; maxelements = 5000)
    # a non-concrete eltype: the schema comes from the snapshot
    anys = fromiter(Any[(x = 1, y = 1.0), (x = 2, y = 2.0)])
    @test mocksource(anys).names == (:x, :y)
end
