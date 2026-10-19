# Documenter build (ADR-0008). Run: julia scripts/ci.jl docs
using Documenter
using ChuiTypes

DocMeta.setdocmeta!(ChuiTypes, :DocTestSetup, :(using ChuiTypes); recursive = true)

makedocs(;
    modules = [ChuiTypes],
    sitename = "ChuiTypes.jl",
    authors = "Boniface Makone",
    format = Documenter.HTML(; prettyurls = get(ENV, "CI", "false") == "true"),
    pages = ["Home" => "index.md"],
    # No git remote yet (pushing waits for the user). Remove once the repo has its GitHub remote.
    remotes = nothing,
)

# deploydocs waits for the user's approval to push (ADR-0008 §1).
