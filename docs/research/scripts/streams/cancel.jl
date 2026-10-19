# Cancellation sketch: a pull-based batch stream backed by a bounded Channel, with a scoped
# consumer that closes the channel on exit (early break, error) so the producer task unwinds
# and runs its finalizer. Shows that cancellation is cooperative: it lands at the producer's
# next blocking point (put!), as InvalidStateException.
println("VERSION = ", VERSION)

struct BatchStream
    ch::Channel{Vector{Int}}
    task::Task
    log::Vector{String}
end
function batches(n_batches; size = 4, buffer = 2)
    log = String[]
    ch = Channel{Vector{Int}}(buffer)
    t = @async begin
        try
            push!(log, "acquire")              # e.g. open a file / socket
            for b in 1:n_batches
                put!(ch, collect(((b - 1) * size + 1):(b * size)))
            end
        catch e
            push!(log, "producer saw " * string(typeof(e)))
            e isa InvalidStateException || rethrow()
        finally
            push!(log, "release")              # finalizer always runs
            close(ch)
        end
    end
    return BatchStream(ch, t, log)
end
# Scoped consumption: the stream is closed whatever way `f` exits.
function withbatches(f, s::BatchStream)
    return try
        f(s.ch)
    finally
        close(s.ch)
        wait(s.task)            # deterministic: the producer has finished its finalizer
    end
end

# 1. early exit after 2 batches of an effectively unbounded stream
s = batches(typemax(Int) ÷ 8)
got = withbatches(s) do it
    out = Vector{Int}[]
    for b in it
        push!(out, b)
        length(out) == 2 && break
    end
    out
end
println("1 got ", got, "  producer log ", s.log, "  task done=", istaskdone(s.task))

# 2. consumer throws mid-stream
s2 = batches(100)
try
    withbatches(s2) do it
        for b in it
            b[1] > 4 && error("consumer failed")
        end
    end
catch e
    println("2 consumer error ", e isa ErrorException ? e.msg : e, "; producer log ", s2.log)
end

# 3. outside cancellation of a consuming task: interrupt it with schedule(t, ex; error=true)
s3 = batches(typemax(Int) ÷ 8)
consumer = @async withbatches(s3) do it
    for b in it
        sleep(0.01)
    end
end
sleep(0.05)
schedule(consumer, InterruptException(); error = true)
r = try
    wait(consumer); "finished"
catch e
    "consumer failed with " * string(typeof(e.task.exception))
end
println("3 ", r, "; producer log ", s3.log)
