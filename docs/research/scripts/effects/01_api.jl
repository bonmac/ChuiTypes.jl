# EFF: which task-cancellation-like names exist in Base on this Julia version
println("VERSION = ", VERSION, "  nthreads = ", Threads.nthreads())
for (m, s) in [
        (Base, :cancel), (Base, :cancel!), (Base, :throwto), (Base, :istaskfailed),
        (Base, :errormonitor), (Base, :ScopedValues), (Base, :Event), (Base, :timedwait),
        (Base, :CancellationToken), (Base.Threads, :cancel), (Base.Experimental, :cancel),
        (Base.Experimental, :task_metrics), (Base, :waitany), (Base, :waitall),
        (Base, :OncePerTask), (Base, :Lockable), (Base, :istaskstarted),
    ]
    println(rpad("$(m).$(s)", 36), isdefined(m, s))
end
println("Base.Experimental names: ", filter(n -> occursin(r"(?i)cancel|task|interrupt", String(n)), names(Base.Experimental; all = true)))
println("Base names matching cancel: ", filter(n -> occursin(r"(?i)cancel", String(n)), names(Base; all = true)))
