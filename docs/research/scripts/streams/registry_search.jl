# Search the local General registry snapshot (read-only) for stream-ish packages.
const TGZ = expanduser("~/.julia/registries/General.tar.gz")
reg = read(`tar -xzOf $TGZ Registry.toml`, String)
lines = split(reg, '\n')
println("total entries: ", count(l -> occursin("name = ", l), lines))
pat = r"name = \"([^\"]*(Rx|Rocket|Observ|Signal|Reactive|Stream|Transducer|Resumable|Continuable|IterTools|Flow|Channel|Pipe|Lazy|Fold)[^\"]*)\", path = \"([^\"]+)\""i
for l in lines
    m = match(pat, l)
    m === nothing || println(m[1], "  ", m[3])
end
# Versions + compat for chosen packages
function pkgfile(path, f)
    return try
        read(`tar -xzOf $TGZ $(path)/$(f)`, String)
    catch
        ""
    end
end
for name in ARGS
    for l in lines
        m = match(Regex("name = \"$(name)\", path = \"([^\"]+)\""), l)
        m === nothing && continue
        p = m[1]
        v = pkgfile(p, "Versions.toml")
        vs = [mm[1] for mm in eachmatch(r"\[\"([^\"]+)\"\]", v)]
        println("== ", name, " path=", p, " nversions=", length(vs), " latest=", isempty(vs) ? "-" : vs[end])
        pk = pkgfile(p, "Package.toml")
        println(strip(pk))
        c = pkgfile(p, "Compat.toml")
        # print last block of compat (sections are version ranges)
        blocks = split(c, "\n\n")
        println("-- Compat (last 2 blocks):\n", join(blocks[max(1, end - 1):end], "\n"))
        d = pkgfile(p, "Deps.toml")
        dblocks = split(d, "\n\n")
        println("-- Deps (last 2 blocks):\n", join(dblocks[max(1, end - 1):end], "\n"))
    end
end
