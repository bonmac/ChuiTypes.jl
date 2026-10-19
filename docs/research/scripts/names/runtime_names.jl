using Statistics, LinearAlgebra, Dates, Random, Test, Distributed, Sockets, Printf, Logging, SparseArrays, InteractiveUtils, Markdown, Serialization, SharedArrays, UUIDs, Unicode, Mmap, DelimitedFiles, FileWatching, Base64, SHA, TOML, Profile, REPL, Pkg, LibGit2, Downloads, Tar
ms = filter(m -> m isa Module, [Base, Core, (getfield(Main, n) for n in names(Main; imported = true) if isdefined(Main, n))...]) |> unique
cands = (:delay, :clocktime, :Cancelled, :EffectFailed, :Interrupted, :Queue, :async, :fromtask, :totask, :fromchannel, :tochannel, :race, :racefirst, :forkscoped, :interrupt!, :await, :checkcancel, :Supervisor, :Fail, :Die, :Success, :Failure, :Error, :TestClock, :advance!, :VirtualClock, :Clock, :Hub, :Subject, :Chunk, :timeoutfail, :Duration)
println(VERSION, " modules checked: ", length(ms))
for n in cands
    h = [nameof(m) for m in ms if isdefined(m, n) && Base.isexported(m, n)]
    println(rpad(string(n), 16), isempty(h) ? "free" : join(h, ","))
end
