# Per-item cost of moving Ints through: iterator, transducer-like fold, push callbacks,
# Channel (buffer 0/64/1024; @async same-thread vs Threads.@spawn), and 1024-chunked variants.
# Pipeline in every case: map(x -> x + 1) |> filter(x -> x % 3 != 0) |> sum.
# Input is a runtime Vector{Int} (no constant folding). Dependency-free timing:
# minimum over R runs of time_ns() deltas, after a warm-up (checked) run.
# Per-item Int-channel cases use NI items (default 10^5) because a per-item task handoff is slow;
# every other case uses N = 10^6. Results are reported per item, so they are comparable.
const N = 10^6
const NI = parse(Int, get(ENV, "NI", "100000"))
const CH = 1024
const R = parse(Int, get(ENV, "REPS", "5"))
f(x) = x + 1
p(x) = x % 3 != 0
const DATA = collect(1:N)
const DATAI = collect(1:NI)
expected(v) = (
    s = 0; for x in v
        y = f(x); p(y) && (s += y)
    end; s
)
const EXP = expected(DATA)
const EXPI = expected(DATAI)

# 1. generator / Base.Iterators
iter_gen(v) = sum(Iterators.filter(p, Iterators.map(f, v)); init = 0)

# 2. transducer-like: reducing-function transformers, then foldl
struct MapRF{F, R}
    f::F; rf::R
end
struct FilterRF{P, R}
    p::P; rf::R
end
(m::MapRF)(acc, x) = m.rf(acc, m.f(x))
(q::FilterRF)(acc, x) = q.p(x) ? q.rf(acc, x) : acc
xf_fold(v) = foldl(MapRF(f, FilterRF(p, +)), v; init = 0)

# 3. push: hand-written mini observable, subscribe(obs, onnext)
abstract type Obs end
struct FromVec <: Obs
    v::Vector{Int}
end
struct MapObs{F, O <: Obs} <: Obs
    f::F; src::O
end
struct FilterObs{P, O <: Obs} <: Obs
    p::P; src::O
end
subscribe(o::FromVec, onnext) = (
    for x in o.v
        onnext(x)
    end; nothing
)
subscribe(o::MapObs, onnext) = subscribe(o.src, x -> onnext(o.f(x)))
subscribe(o::FilterObs, onnext) = subscribe(o.src, x -> (o.p(x) && onnext(x); nothing))
function push_sum(v)
    acc = Ref(0)
    subscribe(FilterObs(p, MapObs(f, FromVec(v))), x -> (acc[] += x; nothing))
    return acc[]
end
# 3b. push with chunks: onnext receives a view of 1024 items
function push_chunk_sum(v)
    acc = Ref(0)
    onchunk = c -> (
        s = 0; for x in c
            y = f(x); p(y) && (s += y)
        end; acc[] += s; nothing
    )
    for lo in 1:CH:length(v)
        onchunk(view(v, lo:min(lo + CH - 1, length(v))))
    end
    return acc[]
end

# 4. Channel of Int
function chan_sum(v, sz, spawn::Bool)
    ch = Channel{Int}(sz)
    prod = () -> (
        for x in v
            put!(ch, x)
        end; close(ch)
    )
    t = spawn ? Threads.@spawn(prod()) : @async(prod())
    s = 0
    for x in ch
        y = f(x)
        p(y) && (s += y)
    end
    wait(t)
    return s
end
# 5. Channel of chunks (fresh Vector{Int} of 1024 per chunk: models batch allocation)
function chan_chunk_sum(v, sz, spawn::Bool)
    ch = Channel{Vector{Int}}(sz)
    prod = () -> (
        for lo in 1:CH:length(v)
            put!(ch, v[lo:min(lo + CH - 1, length(v))])
        end; close(ch)
    )
    t = spawn ? Threads.@spawn(prod()) : @async(prod())
    s = 0
    for c in ch
        for x in c
            y = f(x)
            p(y) && (s += y)
        end
    end
    wait(t)
    return s
end

const SINK = Ref(0)
function bench(name, g, v, ex)
    @assert g(v) == ex name
    best = typemax(UInt64)
    for _ in 1:R
        t0 = time_ns(); SINK[] += g(v); best = min(best, time_ns() - t0)   # SINK defeats dead-code elimination
    end
    println(rpad(name, 36), lpad(string(round(best / length(v); digits = 2)), 9), " ns/item  (n=", length(v), ", min of ", R, ")")
    return flush(stdout)
end

println("VERSION=", VERSION, " nthreads(:default)=", Threads.nthreads(:default), " nthreads(:interactive)=", Threads.nthreads(:interactive), " N=", N, " NI=", NI, " chunk=", CH)
# Calibration: raw Task switch (yieldto, bypasses the scheduler) vs one libuv poll (Base.process_events,
# which the scheduler runs when a task blocks). Explains the per-item Channel cost on this machine.
function yt(n)
    main = current_task(); cnt = Ref(0)
    t = Task(
        () -> while true
            cnt[] += 1; yieldto(main)
        end
    )
    for _ in 1:n
        yieldto(t)
    end
    return cnt[]
end
yt(10)
println(rpad("calib: raw yieldto round trip", 36), lpad(string(round(@elapsed(yt(100_000)) / 100_000 * 1.0e9; digits = 1)), 9), " ns")
println(
    rpad("calib: Base.process_events()", 36), lpad(
        string(
            round(
                @elapsed(
                    for _ in 1:2000
                        Base.process_events()
                    end
                ) / 2000 * 1.0e9; digits = 1
            )
        ), 9
    ), " ns/call"
)
bench("iterator (Iterators.map/filter)", iter_gen, DATA, EXP)
bench("transducer-like foldl", xf_fold, DATA, EXP)
bench("push callbacks (mini observable)", push_sum, DATA, EXP)
bench("push callbacks, chunks of 1024", push_chunk_sum, DATA, EXP)
for spawn in (false, true), sz in (0, 64, 1024)
    bench("Channel{Int}($sz) " * (spawn ? "@spawn" : "@async"), v -> chan_sum(v, sz, spawn), DATAI, EXPI)
end
for spawn in (false, true), sz in (0, 4)
    bench("Channel{Vector}($sz) x1024 " * (spawn ? "@spawn" : "@async"), v -> chan_chunk_sum(v, sz, spawn), DATA, EXP)
end
