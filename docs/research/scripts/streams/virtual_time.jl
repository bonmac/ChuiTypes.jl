# Toy virtual-time scheduler + marble parser + debounce, dependency-free.
# Time only advances when the scheduler pops the next (time, seq, action); nothing sleeps.
println("VERSION = ", VERSION)

mutable struct VirtualScheduler
    now::Int
    seq::Int
    queue::Vector{Tuple{Int, Int, Any}}   # kept sorted by (time, seq): FIFO among equal times
end
VirtualScheduler() = VirtualScheduler(0, 0, Tuple{Int, Int, Any}[])
struct TimerHandle
    s::VirtualScheduler
    id::Int
end
function schedule_at!(s::VirtualScheduler, t::Int, action)
    s.seq += 1
    item = (t, s.seq, action)
    i = searchsortedlast(s.queue, item; by = x -> (x[1], x[2]))
    insert!(s.queue, i + 1, item)
    return TimerHandle(s, s.seq)
end
schedule_after!(s, dt, action) = schedule_at!(s, s.now + dt, action)
cancel!(h::TimerHandle) = filter!(x -> x[2] != h.id, h.s.queue)
function run!(s::VirtualScheduler)
    while !isempty(s.queue)
        t, _, action = popfirst!(s.queue)
        s.now = t
        action()
    end
    return s.now
end

# Observer = (onnext, oncomplete). A cold observable here is just a function subscribe(sched, obs).
struct Observer{N, C}
    onnext::N
    oncomplete::C
end

# Marble: each char is one frame of `frame` time units; '-' = nothing; '|' = complete; letters = values.
function cold(marble::AbstractString; frame = 10)
    return (s, obs) -> begin
        for (i, c) in enumerate(marble)
            t = s.now + (i - 1) * frame
            c == '-' && continue
            if c == '|'
                schedule_at!(s, t, () -> obs.oncomplete())
            else
                schedule_at!(s, t, () -> obs.onnext(c))
            end
        end
    end
end

# debounce(dt): emit a value only after `dt` of silence; on completion flush the pending value.
function debounce(src, dt)
    return (s, obs) -> begin
        pending = Ref{Any}(nothing)
        timer = Ref{Union{Nothing, TimerHandle}}(nothing)
        src(
            s, Observer(
                v -> begin
                    timer[] === nothing || cancel!(timer[])
                    pending[] = v
                    timer[] = schedule_after!(s, dt, () -> (obs.onnext(pending[]); pending[] = nothing; timer[] = nothing))
                end,
                () -> begin
                    if timer[] !== nothing
                        cancel!(timer[]); obs.onnext(pending[]); timer[] = nothing
                    end
                    obs.oncomplete()
                end,
            )
        )
    end
end

# throttle(dt) (leading edge): emit a value, then ignore values for dt.
function throttle(src, dt)
    return (s, obs) -> begin
        open_at = Ref(typemin(Int))
        src(s, Observer(v -> (s.now >= open_at[] && (obs.onnext(v); open_at[] = s.now + dt)), () -> obs.oncomplete()))
    end
end

# Record results back into a marble string (one char per frame, '(...)' grouping omitted for the toy).
function record(obs_fn; frame = 10)
    s = VirtualScheduler()
    out = Tuple{Int, Char}[]
    obs_fn(s, Observer(v -> push!(out, (s.now, v)), () -> push!(out, (s.now, '|'))))
    wall = @elapsed run!(s)
    return out, s.now, wall
end

input = "-a-bc----d--e-f|"
for (name, op) in (("debounce(20)", src -> debounce(src, 20)), ("throttle(30)", src -> throttle(src, 30)))
    out, vend, wall = record(op(cold(input)))
    println(rpad(name, 13), " input  ", input)
    println(rpad("", 13), " output ", out, "  virtual end t=", vend, "  wall=", round(wall * 1.0e6; digits = 1), " us")
end
# Deterministic: same answer on every run.
outs = [record(debounce(cold(input), 20))[1] for _ in 1:100]
println("deterministic over 100 runs: ", all(==(outs[1]), outs))
# Note the tie at t=30: a's debounce timer and b are both due; b was scheduled first (lower seq), so
# b cancels a's timer and 'a' is never emitted. Same-time ordering is a semantic choice to specify.
@assert outs[1] == [(60, 'c'), (110, 'd'), (150, 'f'), (150, '|')]
println("assertion passed: debounce(20) == [(60,'c'),(110,'d'),(150,'f'),(150,'|')]")
