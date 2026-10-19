# Print julia compat, direct deps, latest version for candidate packages, from the installed packages' Project.toml
using Pkg, TOML
for (name, uuid) in [("SumTypes", "8e1ec7a9"), ("Moshi", "2e0e35c7"), ("LightSumTypes", "f56206fc"), ("MLStyle", "d8e11817"), ("ResultTypes", "08a2b407"), ("ErrorTypes", "7f495686"), ("Expronicon", "6b7a57c9"), ("Unityper", "a7c27f48")]
    m = Base.require(Main, Symbol(name)) # load
    dir = pkgdir(m)
    p = TOML.parsefile(joinpath(dir, "Project.toml"))
    println(
        rpad(name, 14), " v", p["version"], " julia=", get(get(p, "compat", Dict()), "julia", "(none)"),
        " deps=", sort(collect(keys(get(p, "deps", Dict())))), " weakdeps=", sort(collect(keys(get(p, "weakdeps", Dict()))))
    )
end
