# Channel semantics relevant to stream backpressure / termination / errors.
println("VERSION = ", VERSION, "  threads = ", Threads.nthreads())

# --- A: bounded channel blocks the producer (backpressure by blocking) ---
ch = Channel{Int}(4)
produced = Int[]
t0 = time()
prod = @async begin
    for i in 1:10
        put!(ch, i)
        push!(produced, i)
    end
    close(ch)
end
sleep(0.2)   # consumer has not started yet
println(
    "A1 after 0.2s without consumer: produced=", length(produced), " buffered=", Base.n_avail(ch),
    " producer state=", istaskdone(prod) ? "done" : "blocked in put!"
)
got = Int[]
for x in ch          # slow consumer
    push!(got, x)
    sleep(0.01)
end
println("A2 consumer got ", got, "; iteration ended after close (isopen=", isopen(ch), ")")

# --- B: close(ch, ex): what does the consumer see? ---
struct MyErr <: Exception
    msg::String
end
ch2 = Channel{Int}(2)
put!(ch2, 1)
close(ch2, MyErr("boom"))
println("B1 isopen=", isopen(ch2), " isready=", isready(ch2))
println("B2 take! of buffered item after close(ch,ex): ", take!(ch2))
try
    take!(ch2)
catch e
    println("B3 take! on empty closed-with-ex channel threw: ", typeof(e), " => ", e)
end
ch3 = Channel{Int}(2); put!(ch3, 1); close(ch3, MyErr("boom-iter"))
try
    for x in ch3
        println("B4 iterated ", x)
    end
    println("B4 iteration ended normally (no throw)")
catch e
    println("B4 iteration threw: ", typeof(e), " => ", e)
end
ch4 = Channel{Int}(2); close(ch4)
try
    take!(ch4)
catch e
    println("B5 take! on plain-closed empty channel threw: ", typeof(e))
end

# --- C: bind(ch, task) where the task fails ---
ch5 = Channel{Int}(1)
t5 = @async begin
    put!(ch5, 1)
    put!(ch5, 2)
    error("producer failed")
end
bind(ch5, t5)
items = Int[]
try
    for x in ch5
        push!(items, x)
    end
    println("C1 iteration ended normally, items=", items)
catch e
    println("C1 consumer saw: ", typeof(e), " items=", items)
    if e isa TaskFailedException
        println("C1 inner: ", typeof(e.task.exception), " => ", e.task.exception)
    end
end
# Channel(f) constructor form with failing f (implicit bind)
ch6 = Channel{Int}(1) do c
    put!(c, 1)
    throw(MyErr("in Channel(f)"))
end
try
    collect(ch6)
catch e
    println(
        "C2 Channel(f) failing f: consumer saw ", typeof(e),
        e isa TaskFailedException ? " inner=$(typeof(e.task.exception))" : ""
    )
end

# --- D: consumer-side cancellation: closing the channel unblocks a waiting producer ---
ch7 = Channel{Int}(1)
p7 = @async try
    for i in 1:typemax(Int)
        put!(ch7, i)
    end
catch e
    e
end
take!(ch7); take!(ch7)
close(ch7)          # consumer "cancels"
r = fetch(p7)
println("D1 producer blocked in put! after consumer close(ch) gets: ", typeof(r))

# --- E: Base.Iterators laziness + early break releases nothing automatically ---
ch8 = Channel{Int}(0)
p8 = @async (
    for i in 1:100
        put!(ch8, i)
    end; close(ch8)
)
first3 = collect(Iterators.take(ch8, 3))
sleep(0.05)
println("E1 took ", first3, "; producer done after take(3)? ", istaskdone(p8), " (blocked forever unless channel closed)")
close(ch8); sleep(0.05)
println("E2 after close(ch): producer done=", istaskdone(p8), " failed=", istaskfailed(p8))
