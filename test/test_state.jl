@testitem "State: constructors, layout, run" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    const T = ChuiTypes.StateTag{Int}()
    @test getstate(Int) isa State{Int}
    @test isconcretetype(State{Int})
    @test fieldcount(State{Int}) == 1
    @test putstate(3) isa State{Int}
    @test putstate(Int, 0x01) isa State{Int}
    @test modifystate(x -> x + 1, Int) isa State{Int}
    @test U.pure(T, "a") isa State{Int}
    # putstate(S, x) converts when the value is built
    @test runstate(putstate(Int, 0x01), 5) === (nothing, 1)
    @test_throws InexactError putstate(Int, 1.5)
    @test runstate(getstate(Int), 4) === (4, 4)
    @test runstate(getstate(Int), 0x02) === (2, 2)                 # s0 converted to S
    @test runstate(modifystate(x -> 2x, Int), 4) === (nothing, 8)
    @test runstate(U.pure(T, :a), 1) === (:a, 1)
    incr = andthen(s -> putstate(s + 1), getstate(Int))
    @test runstate(andthen(_ -> getstate(Int), incr), 1) === (2, 2)
    @test runstate(map(s -> s * 10, getstate(Int)), 3) === (30, 3)
    @test runstate(U.fmap(string, getstate(Int)), 3) == ("3", 3)
    @test U.chain(s -> putstate(-s), getstate(Int)) isa State{Int}
    # ap runs the function's effects first
    ff = andthen(s -> andthen(_ -> U.pure(T, x -> (x, s)), putstate(s + 1)), getstate(Int))
    @test runstate(U.ap(ff, getstate(Int)), 1) === ((2, 1), 2)
    # an abstract declared state type is kept
    @test runstate(putstate(Any, 1), nothing) === (nothing, 1)
    @test runstate(putstate(Real, 1.5), 0)[2] === 1.5
end

@testitem "State: declared result type, wrong continuation" tags = [:unit] begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    const T = ChuiTypes.StateTag{Int}()
    @test runstate(U.pure(T, 1), 0, Int) === (1, 0)
    @test_throws TypeError runstate(U.pure(T, 1), 0, String)
    @test Base.return_types(runstate, (State{Int}, Int)) == [Tuple{Any, Int}]
    @test Base.return_types(runstate, (State{Int}, Int, Type{Int})) == [Tuple{Int, Int}]
    @test (@inferred Tuple{Any, Int} runstate(getstate(Int), 0)) === (0, 0)
    @test (@inferred runstate(getstate(Int), 0, Int)) === (0, 0)
    bad = andthen(_ -> putstate(0x01), getstate(Int))
    err = try
        runstate(bad, 0)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("State{Int64}", err.msg) && occursin("State{UInt8}", err.msg)
    err2 = try
        runstate(andthen(_ -> 1, getstate(Int)), 0)
        nothing
    catch e
        e
    end
    @test err2 isa ArgumentError && occursin("State{Int64}", err2.msg) && occursin("Int64", err2.msg)
    # a Reader is not a State either
    @test_throws ArgumentError runstate(andthen(_ -> ask(Int), getstate(Int)), 0)
end

@testitem "State: identity semantics, show, sharing" tags = [:unit] begin
    using ChuiTypes
    left_chain(n) = foldl((m, _) -> andthen(_ -> modifystate(s -> s + 1, Int), m), 1:n; init = putstate(0))
    a, b = left_chain(10^5), left_chain(10^5)
    # no == / hash methods: identity, which is O(1) even on deep programs
    @test a === a && a == a && isequal(a, a)
    @test a !== b && a != b
    @test hash(a) isa UInt
    @test repr(getstate(Int)) == "State{$Int}(…)"
    @test repr(a) == "State{$Int}(…)"
    # a value can be run concurrently: each run owns its stack
    ts = [Threads.@spawn(runstate(a, i)) for i in 1:4]
    @test [fetch(t)[2] for t in ts] == [10^5 for _ in 1:4]
end

@testitem "State: stack safety at 10^5" tags = [:unit] begin
    using ChuiTypes
    const T = ChuiTypes.StateTag{Int}()
    incr = _ -> andthen(s -> putstate(s + 1), getstate(Int))
    left_chain(n) = foldl((m, _) -> andthen(incr, m), 1:n; init = ChuiTypes.Upstream.pure(T, nothing))
    step(m) = andthen(_ -> m, incr(nothing))            # `m` is an argument: not a boxed capture
    right_chain(n) = foldl((m, _) -> step(m), 1:n; init = ChuiTypes.Upstream.pure(T, nothing))
    map_chain(n) = foldl((m, _) -> map(x -> x + 1, m), 1:n; init = getstate(Int))
    n = 10^5
    @test runstate(left_chain(n), 0) === (nothing, n)
    @test runstate(right_chain(n), 0) === (nothing, n)
    @test runstate(map_chain(n), 0) === (n, 0)
end

@testitem "State: stack safety at 10^6" tags = [:slow] begin
    using ChuiTypes
    const T = ChuiTypes.StateTag{Int}()
    incr = _ -> andthen(s -> putstate(s + 1), getstate(Int))
    left_chain(n) = foldl((m, _) -> andthen(incr, m), 1:n; init = ChuiTypes.Upstream.pure(T, nothing))
    step(m) = andthen(_ -> m, incr(nothing))            # `m` is an argument: not a boxed capture
    right_chain(n) = foldl((m, _) -> step(m), 1:n; init = ChuiTypes.Upstream.pure(T, nothing))
    n = 10^6
    @test runstate(left_chain(n), 0) === (nothing, n)
    @test runstate(right_chain(n), 0) === (nothing, n)
end
