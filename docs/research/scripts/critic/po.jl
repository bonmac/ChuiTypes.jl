f(x) = g(x)                       # g not yet defined
T1 = Base.promote_op(f, Int)
println(VERSION, " promote_op(f, Int) before g exists: ", T1)
g(x) = x + 1
println(
    "after g defined, f(1)::T1 -> ", try
        f(1)::T1
    catch e
        typeof(e)
    end
)
h(x) = x > 0 ? x : error("neg")
println("promote_op(h,Int) = ", Base.promote_op(h, Int), "  promote_op(x->error(), Int)=", Base.promote_op(x -> error("x"), Int))
# recursion / deep: Any
k(x) = x isa Int ? string(x) : x
println("promote_op(k, Any)=", Base.promote_op(k, Any))
