# Effect->Task: can a Base Task's fetch ever throw the original exception?
struct Boom <: Exception end
t = Threads.@spawn throw(Boom())
r = try
    fetch(t); :noerr
catch e
    (typeof(e), e isa TaskFailedException && e.task.exception isa Boom)
end
println(VERSION, " fetch threw: ", r)
# rethrow-from-body variant (what EFF-05 suggests)
t2 = Task(
    () -> try
        error("x")
    catch
        rethrow(Boom())
    end
); schedule(t2)
r2 = try
    fetch(t2); :noerr
catch e
    typeof(e)
end
println(VERSION, " body rethrows original -> fetch threw: ", r2)
# Task constructed outside a scoped value scope does not see the token (EFF-09) -> a foreign task cannot observe our token
