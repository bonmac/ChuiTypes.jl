# ADR-0001: an assertion against Base.promote_op goes stale when a more specific method is added later.
g(x::Integer) = 1
f(x) = g(x)
A = Base.promote_op(f, Int)
g(x::Int) = "late"
println(
    VERSION, " A=", A, " f(1)::A -> ", try
        f(1)::A
    catch e
        e
    end
)
println(VERSION, " ispublic(Base, :promote_op) = ", isdefined(Base, :ispublic) ? Base.ispublic(Base, :promote_op) : "n/a (no Base.ispublic)")
