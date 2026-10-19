using Statistics, LinearAlgebra, Dates, Random, Test, Distributed, Sockets, Printf, Logging, SparseArrays, InteractiveUtils, Markdown, Serialization, SharedArrays, UUIDs, Unicode, Mmap, DelimitedFiles, FileWatching, Base64, SHA, TOML, Profile, REPL, Pkg, LibGit2, Downloads, Tar
ms = filter(m -> m isa Module, [Base, Core, (getfield(Main, n) for n in names(Main; imported = true) if isdefined(Main, n))...]) |> unique
cands = (:some, :none, :left, :right, :valid, :invalid, :this, :that, :both, :nonempty, :Option, :Either, :Validation, :These, :NonEmpty, :LazyList, :Reader, :Writer, :State, :Effect, :Exit, :Cause, :Fiber, :Scope, :Schedule, :Stream, :runexit, :runstate, :withbatches, :provide, :service, :uninterruptible, :timeout, :bracket, :Action)
println(VERSION, " modules checked: ", length(ms))
for n in cands
    h = [nameof(m) for m in ms if isdefined(m, n) && Base.isexported(m, n)]
    println(rpad(string(n), 16), isempty(h) ? "free" : join(h, ","))
end
