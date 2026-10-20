@testsnippet WriterMonoids begin
    using ChuiTypes
    const U = ChuiTypes.Upstream
    struct SumM end                                    # Int sum
    U.combine(::SumM, a::Int, b::Int) = a + b
    U.neutral(::SumM) = 0
    struct AppendM end                                 # Vector log, in place into the accumulator
    U.combine(::AppendM, a::Vector{Int}, b::Vector{Int}) = append!(a, b)
    U.neutral(::AppendM) = Int[]
    struct CatM end                                    # Vector log, copying
    U.combine(::CatM, a::Vector{Int}, b::Vector{Int}) = vcat(a, b)
    U.neutral(::CatM) = Int[]
    struct StrM end                                    # not commutative: shows the order
    U.combine(::StrM, a::String, b::String) = a * b
    U.neutral(::StrM) = ""
    mutable struct CountingM                           # counts neutral calls
        n::Int
    end
    U.combine(::CountingM, a::Int, b::Int) = a + b
    U.neutral(c::CountingM) = (c.n += 1; 0)
end

@testitem "Writer: constructors, layout, run" tags = [:unit] setup = [WriterMonoids] begin
    const T = ChuiTypes.WriterTag{Int}()
    @test tell(1) isa Writer{Int}
    @test tell([1]) isa Writer{Vector{Int}}
    @test tell(Float64, 1) isa Writer{Float64}
    @test isconcretetype(Writer{Int})
    @test fieldcount(Writer{Int}) == 1
    @test U.pure(T, :a) isa Writer{Int}
    @test runwriter(tell(3), SumM()) === (nothing, 3)
    @test runwriter(U.pure(T, :a), SumM()) === (:a, 0)
    @test runwriter(andthen(_ -> tell(2), tell(1)), SumM()) === (nothing, 3)
    @test runwriter(map(_ -> 5, tell(1)), SumM()) === (5, 1)
    @test runwriter(U.fmap(_ -> 5, tell(1)), SumM()) === (5, 1)
    @test runwriter(U.chain(_ -> tell(2), tell(1)), SumM()) === (nothing, 3)
    # execution order: the accumulator is combine(acc, w)
    ab = andthen(_ -> tell("b"), tell("a"))
    @test runwriter(ab, StrM()) == (nothing, "ab")
    ff = andthen(_ -> U.pure(ChuiTypes.WriterTag{String}(), x -> x), tell("f"))
    @test runwriter(U.ap(ff, tell("x")), StrM()) == (nothing, "fx")
    # in-place and copying monoids give the same log; running twice does not grow it
    m = andthen(_ -> andthen(_ -> tell([3]), tell([2])), tell([1]))
    @test runwriter(m, AppendM()) == (nothing, [1, 2, 3])
    @test runwriter(m, AppendM()) == (nothing, [1, 2, 3])
    @test runwriter(m, CatM()) == (nothing, [1, 2, 3])
    # neutral is called once per run
    c = CountingM(0)
    @test runwriter(andthen(_ -> tell(2), tell(1)), c) === (nothing, 3)
    @test c.n == 1
end

@testitem "Writer: listening and censor" tags = [:unit] setup = [WriterMonoids] begin
    inner = andthen(_ -> andthen(_ -> U.pure(ChuiTypes.WriterTag{Vector{Int}}(), :v), tell([2])), tell([1]))
    @test listening(inner) isa Writer{Vector{Int}}
    m = andthen(_ -> listening(inner), tell([0]))
    for mon in (AppendM(), CatM())
        @test runwriter(m, mon) == ((:v, [1, 2]), [0, 1, 2])
        @test runwriter(andthen(_ -> tell([9]), m), mon) == (nothing, [0, 1, 2, 9])
    end
    @test censor(reverse, tell([1, 2])) isa Writer{Vector{Int}}
    cm = andthen(_ -> andthen(_ -> tell([3]), censor(reverse, andthen(_ -> tell([2]), tell([1])))), tell([0]))
    for mon in (AppendM(), CatM())
        @test runwriter(cm, mon) == (nothing, [0, 2, 1, 3])
    end
    @test runwriter(censor(x -> 10x, andthen(_ -> U.pure(ChuiTypes.WriterTag{Int}(), :r), tell(2))), SumM()) === (:r, 20)
    # listening inside censor: the value keeps the uncensored log
    @test runwriter(censor(_ -> [7], listening(tell([1]))), AppendM()) == ((nothing, [1]), [7])
end

@testitem "Writer: declared result type, wrong continuation, show" tags = [:unit] setup = [WriterMonoids] begin
    @test runwriter(map(_ -> 1, tell(1)), SumM(), Int) === (1, 1)
    @test_throws TypeError runwriter(tell(1), SumM(), Int)
    @test Base.return_types(runwriter, (Writer{Int}, SumM, Type{Int})) == [Tuple{Int, Int}]
    @test Base.return_types(runwriter, (Writer{Int}, SumM)) == [Tuple{Any, Int}]
    err = try
        runwriter(andthen(_ -> tell("s"), tell(1)), SumM())
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("Writer{Int64}", err.msg) && occursin("Writer{String}", err.msg)
    @test_throws ArgumentError runwriter(andthen(_ -> nothing, tell(1)), SumM())
    @test repr(tell(1)) == "Writer{$Int}(…)"
end

@testitem "Writer: stack safety at 10^5, left and right give the same log" tags = [:unit] setup = [WriterMonoids] begin
    n = 10^5
    left_chain(n) = foldl((m, i) -> andthen(_ -> tell([i]), m), 2:n; init = tell([1]))
    step(m, i) = andthen(_ -> m, tell([i]))
    right_chain(n) = foldl(step, (n - 1):-1:1; init = tell([n]))
    l, r = runwriter(left_chain(n), AppendM()), runwriter(right_chain(n), AppendM())
    @test l == r == (nothing, collect(1:n))
    lsum(n) = foldl((m, _) -> andthen(_ -> tell(1), m), 2:n; init = tell(1))
    @test runwriter(lsum(n), SumM()) === (nothing, n)
    # each level adds the length of the log it heard (a nested tuple 10^5 deep would be a
    # pathological value, not a test of the run)
    nestl(n) = foldl((m, _) -> map(p -> p[1] + length(p[2]), listening(m)), 1:n; init = map(_ -> 0, tell([1])))
    @test runwriter(andthen(_ -> nestl(n), tell([0])), AppendM()) == (n, [0, 1])
    nestc(n) = foldl((m, _) -> censor(x -> x + 1, m), 1:n; init = tell(1))
    @test runwriter(andthen(_ -> nestc(n), tell(5)), SumM()) === (nothing, 5 + 1 + n)
end

@testitem "Writer: stack safety at 10^6" tags = [:slow] setup = [WriterMonoids] begin
    n = 10^6
    left_chain(n) = foldl((m, _) -> andthen(_ -> tell(1), m), 2:n; init = tell(1))
    step(m) = andthen(_ -> m, tell(1))
    right_chain(n) = foldl((m, _) -> step(m), 2:n; init = tell(1))
    @test runwriter(left_chain(n), SumM()) === (nothing, n)
    @test runwriter(right_chain(n), SumM()) === (nothing, n)
    nestc(n) = foldl((m, _) -> censor(x -> x + 1, m), 1:n; init = tell(1))
    @test runwriter(nestc(n), SumM()) === (nothing, 1 + n)
end
