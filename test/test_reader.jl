@testitem "Reader: constructors, layout, run" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    const T = ChuiTypes.ReaderTag{Int}()
    @test ask(Int) isa Reader{Int}
    @test isconcretetype(Reader{Int})
    @test fieldcount(Reader{Int}) == 1
    @test asks(x -> 2x, Int) isa Reader{Int}
    @test U.pure(T, "a") isa Reader{Int}
    @test runreader(ask(Int), 3) === 3
    @test runreader(ask(Int), 0x03) === 3                         # environment converted to R
    @test runreader(asks(x -> 2x, Int), 3) === 6
    @test runreader(U.pure(T, :a), 1) === :a
    @test runreader(map(string, ask(Int)), 7) == "7"
    @test runreader(U.fmap(x -> x + 1, ask(Int)), 7) === 8
    @test runreader(andthen(x -> asks(y -> x + y, Int), ask(Int)), 4) === 8
    @test runreader(U.chain(x -> U.pure(T, -x), ask(Int)), 4) === -4
    @test runreader(U.ap(asks(r -> (x -> x * r), Int), ask(Int)), 5) === 25
    # withreader runs its argument in f(r) and restores r afterwards
    @test withreader(x -> x + 1, ask(Int)) isa Reader{Int}
    @test runreader(withreader(x -> x + 1, ask(Int)), 3) === 4
    m = andthen(a -> map(b -> (a, b), ask(Int)), withreader(x -> 10x, ask(Int)))
    @test runreader(m, 2) === (20, 2)
    nested = withreader(x -> x + 1, andthen(a -> map(b -> (a, b), ask(Int)), withreader(x -> 10x, ask(Int))))
    @test runreader(nested, 2) === (30, 3)
    # the continuation inside withreader sees the local environment too
    @test runreader(withreader(x -> 0, andthen(_ -> ask(Int), ask(Int))), 9) === 0
end

@testitem "Reader: declared result type, wrong continuation, show" tags = [:unit] begin
    using ChuiTypes
    @test runreader(ask(Int), 1, Int) === 1
    @test_throws TypeError runreader(ask(Int), 1, String)
    @test Base.return_types(runreader, (Reader{Int}, Int, Type{Int})) == [Int]
    err = try
        runreader(andthen(_ -> ask(String), ask(Int)), 1)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("Reader{Int64}", err.msg) && occursin("Reader{String}", err.msg)
    @test_throws ArgumentError runreader(andthen(_ -> getstate(Int), ask(Int)), 1)
    @test repr(ask(Int)) == "Reader{$Int}(…)"
    m = ask(Int)
    @test m === m && m != asks(identity, Int)
end

@testitem "Reader: stack safety at 10^5" tags = [:unit] begin
    using ChuiTypes
    const T = ChuiTypes.ReaderTag{Int}()
    n = 10^5
    left_chain(n) = foldl((m, _) -> andthen(a -> asks(r -> a + r, Int), m), 1:n; init = ChuiTypes.Upstream.pure(T, 0))
    step(m) = andthen(a -> map(b -> a + b, m), ask(Int))
    right_chain(n) = foldl((m, _) -> step(m), 1:n; init = ChuiTypes.Upstream.pure(T, 0))
    @test runreader(left_chain(n), 1) === n
    @test runreader(right_chain(n), 1) === n
    nest(n) = foldl((m, _) -> withreader(x -> x + 1, m), 1:n; init = ask(Int))
    deep = nest(n)
    @test runreader(deep, 0) === n
    # the environment is restored after the deep withreader
    @test runreader(andthen(a -> map(b -> (a, b), ask(Int)), deep), 0) === (n, 0)
end

@testitem "Reader: stack safety at 10^6" tags = [:slow] begin
    using ChuiTypes
    const T = ChuiTypes.ReaderTag{Int}()
    n = 10^6
    left_chain(n) = foldl((m, _) -> andthen(a -> asks(r -> a + r, Int), m), 1:n; init = ChuiTypes.Upstream.pure(T, 0))
    step(m) = andthen(a -> map(b -> a + b, m), ask(Int))
    right_chain(n) = foldl((m, _) -> step(m), 1:n; init = ChuiTypes.Upstream.pure(T, 0))
    @test runreader(left_chain(n), 1) === n
    @test runreader(right_chain(n), 1) === n
    nest(n) = foldl((m, _) -> withreader(x -> x + 1, m), 1:n; init = ask(Int))
    deep = nest(n)
    @test runreader(andthen(a -> map(b -> (a, b), ask(Int)), deep), 0) === (n, 0)
end
