# ADR-0004: methods written as `Upstream.f(...) = ...` in another file extend ChuiCore's binding,
# whether Upstream imports it (`using ChuiCore: f`) or aliases a renamed one (`const f = ChuiCore.g`).
module ChuiCore
    function flatmap end
    function chain end
    export flatmap, chain
end
module PkgA                       # Upstream imports the binding
    module Upstream;
        using ...ChuiCore: flatmap;
    end
    struct Opt
        v::Int
    end
    Upstream.flatmap(f, o::Opt) = f(o.v)
end
module PkgB                       # Upstream aliases a renamed binding
    module Upstream;
        using ...ChuiCore; const flatmap = ChuiCore.chain;
    end
    struct Opt
        v::Int
    end
    Upstream.flatmap(f, o::Opt) = f(o.v)
end
println(VERSION, " using-import: methods=", length(methods(ChuiCore.flatmap)), " call=", ChuiCore.flatmap(x -> x + 1, PkgA.Opt(1)))
println(VERSION, " const-alias:  methods=", length(methods(ChuiCore.chain)), " call=", ChuiCore.chain(x -> x + 1, PkgB.Opt(1)))
