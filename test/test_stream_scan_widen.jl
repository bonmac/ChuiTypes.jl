# scan widens its accumulator type like Base.accumulate (plan
# docs/superpowers/plans/2026-10-27-scan-widen.md, Task 1; ADR-0009 follow-up 4).
# The Int-only and empty-stream cases already hold and are covered in test_stream.jl.

# Plan Task 1: "`collect(scan(+, 0, fromiter([1, 2.5, 3])))` returns `[1.0, 3.5, 6.5]` (`Float64`)."
@testitem "scan: a Float64 input widens an Int init to Float64" tags = [:unit] begin
    using ChuiTypes
    out = run(runcollect(scan(+, 0, fromiter([1, 2.5, 3]))))
    @test out == [1.0, 3.5, 6.5]
    @test eltype(out) === Float64
end

# Plan Task 1: "the same values, in the same order, as `Base.accumulate(op, collect(s); init = init)`,
# including when `op(init, x)` has a wider type than `init`."
@testitem "scan: matches Base.accumulate when op widens an Int accumulator" tags = [:unit] begin
    using ChuiTypes
    op = (acc, x) -> acc + x / 2
    xs = [1, 2, 3]
    @test run(runcollect(scan(op, 0, fromiter(xs)))) == accumulate(op, xs; init = 0)
end

# Plan Task 1 brief: "A mixed `Any[...]` input also exercises widening part-way through the stream."
@testitem "scan: widens part-way through a mixed-type stream" tags = [:unit] begin
    using ChuiTypes
    xs = Any[1, 2, 2.5, 3]
    @test run(runcollect(scan(+, 0, fromiter(xs)))) == accumulate(+, xs; init = 0)
end

# Plan Task 1: "The accumulator is still carried across chunks: the result does not depend on
# chunking." ADR-0003: stateful operators carry their state across chunks. fromiter docstring:
# `fromiter(itr; chunksize = 1024)`.
@testitem "scan: a widened accumulator does not depend on chunking" tags = [:unit] begin
    using ChuiTypes
    xs = Any[1, 2, 2.5, 3, 4.25, 5]
    expected = accumulate(+, xs; init = 0)
    for n in (1, 2, 4)
        @test run(runcollect(scan(+, 0, fromiter(xs; chunksize = n)))) == expected
    end
end

# Plan Task 1: "The stream's element type covers every emitted value." Stream docstring: `T` is
# "a supertype of every element ... (`eltype(s)` returns it)".
@testitem "scan: the stream eltype covers every widened value" tags = [:unit] begin
    using ChuiTypes
    s = scan(+, 0, fromiter([1, 2.5, 3]))
    out = run(runcollect(s))
    @test all(x -> x isa eltype(s), out)
end
