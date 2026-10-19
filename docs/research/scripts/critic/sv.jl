using Base.ScopedValues
const TOK = ScopedValue{Any}(nothing)
const ENVV = ScopedValue{Any}(nothing)
function reads(n)
    s = 0; for _ in 1:n
        s += TOK[] === nothing ? 1 : 0
    end
    return s
end
function withs(n)
    s = 0; for _ in 1:n
        s += with(() -> 1, TOK => :x)
    end
    return s
end
reads(10); withs(10)
inner() = with(() -> reads(10^6), ENVV => 1, TOK => :t)
for (lbl, f) in (("ScopedValue read, root scope", () -> reads(10^6)), ("ScopedValue read, nested scope", inner), ("with(...) per call", () -> withs(10^6)))
    f(); t = minimum(@elapsed(f()) for _ in 1:5); println(VERSION, "  ", rpad(lbl, 32), round(t / 1.0e6 * 1.0e9, digits = 1), " ns/op")
end
# depth: a recursive provide-like nesting of `with` (what an interpreter that uses `with` for provide/mask must do)
nest(d) = d == 0 ? 0 : with(() -> nest(d - 1), ENVV => d)
for d in (10^4, 10^5)
    r = try
        nest(d); :ok
    catch e
        typeof(e)
    end
    println(VERSION, "  nested with depth $d -> ", r)
end
