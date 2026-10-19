# ADR-0001 §2: Validation with errs::Vector{E} (empty when valid) vs errs::Union{Nothing,Vector{E}}.
struct V{E, A}
    tag::UInt8; errs::Vector{E}; a::Union{Nothing, A}
end
valid(a::A, ::Type{E}) where {A, E} = V{E, A}(0x00, E[], a)
struct V2{E, A}
    tag::UInt8; errs::Union{Nothing, Vector{E}}; a::Union{Nothing, A}
end
valid2(a::A, ::Type{E}) where {A, E} = V2{E, A}(0x00, nothing, a)
g(n) = [valid(i, String) for i in 1:n]
g2(n) = [valid2(i, String) for i in 1:n]
g(1); g2(1)
println(VERSION, " 10^5 valid values: Vector errs allocs=", @allocated(g(10^5)), "  Union{Nothing,Vector} errs allocs=", @allocated(g2(10^5)), "  (output vector alone ~3.2 MB)")
