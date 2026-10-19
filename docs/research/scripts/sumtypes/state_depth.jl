# Does a closure-based State{F} infer concretely as flatmap nesting deepens?
println("julia ", VERSION)
struct State{F}
    run::F
end
st_pure(a) = State(s -> (a, s))
st_flatmap(f, m::State) = State(s -> ((a, s2) = m.run(s); f(a).run(s2)))
const incr = State(s -> (s, s + 1))
const p1 = st_flatmap(a -> st_pure(a), incr)
const p2 = st_flatmap(a -> st_flatmap(b -> st_pure(a + b), incr), incr)
const p3 = st_flatmap(a -> st_flatmap(b -> st_flatmap(c -> st_pure(a + b + c), incr), incr), incr)
# same depth-3 program written with a named, non-recursive bind per level
bind1(m, f) = State(s -> ((a, s2) = m.run(s); f(a).run(s2)))
runp(p, s) = p.run(s)
for (n, p) in (("depth 1", p1), ("depth 2", p2), ("depth 3", p3))
    runp(p, 0)
    println(n, ": run(::Int) -> ", Base.return_types(runp, Tuple{typeof(p), Int})[1], "  @allocated=", @allocated(runp(p, 0)))
end
