# Rocket.jl probe: version, dependency count, subscribe!/operators, a fast producer vs slow actor,
# and push throughput for the same map/filter/sum pipeline. Run with --project=<env dir>.
using Pkg
t_load = @elapsed using Rocket
println("VERSION=", VERSION, "  Rocket ", pkgversion(Rocket), "  load time ", round(t_load; digits = 2), " s")
deps = Pkg.dependencies()
direct = [d for (_, d) in deps if d.name == "Rocket"][1]
println("Rocket direct deps: ", sort(collect(keys(direct.dependencies))))
println("total packages in manifest (transitive, excl. Rocket): ", length(deps) - 1)

# 1. basic: cold from() + operators + subscribe!
got = Int[]
src = from(1:10) |> map(Int, x -> x * 2) |> filter(x -> x % 3 != 0) |> scan(+)
sub = subscribe!(src, lambda(on_next = x -> push!(got, x), on_complete = () -> println("complete")))
println("from(1:10) |> map |> filter |> scan(+) => ", got)

# 2. Subject = hot: late subscriber misses earlier values
s = Subject(Int)
a = Int[]; b = Int[]
sa = subscribe!(s, lambda(on_next = x -> push!(a, x)))
next!(s, 1); next!(s, 2)
sb = subscribe!(s, lambda(on_next = x -> push!(b, x)))
next!(s, 3)
unsubscribe!(sa); next!(s, 4)
println("Subject: early subscriber got ", a, ", late subscriber got ", b)

# 3. backpressure? fast synchronous producer, slow actor: does the producer wait or buffer?
s2 = Subject(Int)
t_emit = Float64[]
slow = lambda(on_next = x -> sleep(0.01))
subscribe!(s2, slow)
t0 = time()
for i in 1:20
    next!(s2, i)
end
println("sync Subject + slow actor (10 ms each): emitting 20 took ", round(time() - t0; digits = 3), " s (producer blocked = synchronous call, no demand signal)")

# async scheduler on a cold source: subscribe_on-style delivery through a Channel
# (AsyncScheduler(size) wraps Channel(size); default size = typemax(Int), i.e. unbounded)
for (label, sch) in (("AsyncScheduler() [unbounded]", AsyncScheduler()), ("AsyncScheduler(4)", AsyncScheduler(4)))
    done = Ref(0)
    emitted = Ref(0)
    src = from(1:50) |> tap(_ -> emitted[] += 1) |> schedule_on(sch)
    subscribe!(src, lambda(on_next = x -> (sleep(0.002); done[] += 1)))
    sleep(0.03)
    println(label, ": after 30 ms emitted=", emitted[], " processed=", done[])
    sleep(0.5)
    println(label, ": after 530 ms emitted=", emitted[], " processed=", done[])
end

# 4. throughput: same pipeline as throughput.jl, 10^6 items through from(vector)
f(x) = x + 1
p(x) = x % 3 != 0
v = collect(1:(10^6))
function rocket_sum(v)
    acc = Ref(0)
    subscribe!(from(v) |> map(Int, f) |> filter(p), lambda(on_next = x -> (acc[] += x; nothing)))
    return acc[]
end
rocket_sum(v)
best = minimum(@elapsed(rocket_sum(v)) for _ in 1:5)
println("Rocket from(vector)|>map|>filter push: ", round(best / length(v) * 1.0e9; digits = 2), " ns/item (min of 5)")
