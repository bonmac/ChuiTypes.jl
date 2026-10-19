# EFF: @sync semantics when one child fails
println("VERSION = ", VERSION, "  nthreads = ", Threads.nthreads())
log = Channel{String}(100)
t0 = time()
try
    @sync begin
        Threads.@spawn begin
            sleep(0.1); put!(log, "A fails at $(round(time() - t0; digits = 2))"); error("A boom")
        end
        Threads.@spawn begin
            sleep(1.0); put!(log, "B finished at $(round(time() - t0; digits = 2))")
        end
        @async begin
            sleep(0.5); put!(log, "C finished at $(round(time() - t0; digits = 2))"); error("C boom")
        end
    end
catch e
    put!(
        log, "@sync threw $(typeof(e)) at $(round(time() - t0; digits = 2)) with $(length(e.exceptions)) exceptions: " *
            join([sprint(showerror, x.task.exception) for x in e.exceptions], " | ")
    )
end
close(log)
foreach(println, log)

# Does the parent's failure (exception thrown in @sync body itself) cancel children?
log2 = Channel{String}(100); t0 = time()
try
    @sync begin
        Threads.@spawn (sleep(0.6); put!(log2, "child still ran to completion at $(round(time() - t0; digits = 2))"))
        error("parent body fails immediately")
    end
catch e
    put!(log2, "@sync threw $(typeof(e)) at $(round(time() - t0; digits = 2))")
end
sleep(1.0)   # give the orphaned child time to finish
close(log2); foreach(println, log2)
