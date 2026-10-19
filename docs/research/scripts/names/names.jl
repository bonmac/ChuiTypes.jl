using Statistics, LinearAlgebra, Dates, Random, Test, Distributed, Sockets, Serialization, SharedArrays, Printf, Logging, UUIDs, Unicode, InteractiveUtils, Markdown, Mmap, SparseArrays, DelimitedFiles, FileWatching, Base64, SHA, TOML, Profile, REPL, Pkg, LibGit2, Downloads, Tar, NetworkOptions, ArgTools, LazyArtifacts, Artifacts
mods = [Base, Core, Statistics, LinearAlgebra, Dates, Random, Test, Distributed, Sockets, Serialization, SharedArrays, Printf, Logging, UUIDs, Unicode, InteractiveUtils, Markdown, Mmap, SparseArrays, DelimitedFiles, FileWatching, Base64, SHA, TOML, Profile, REPL, Pkg, LibGit2, Downloads, Tar]
cands = [
    :Option, :Maybe, :Either, :Result, :Validation, :These, :NonEmpty, :LazyList, :Reader, :Writer, :State, :IO, :Task, :Effect, :Eff, :Fiber, :Scope, :Schedule, :Future, :Stream, :Chunk, :Observable, :Subject, :Some, :None, :Nothing, :Just, :Left, :Right, :Ok, :Err, :Valid, :Invalid, :Exit, :Cause, :IOAction, :Lazy, :Deferred,
    :bind, :run, :retry, :timeout, :merge, :filter, :map, :scan, :concat, :switchmap, :mergemap, :debounce, :throttle, :buffer, :window, :fold, :flatmap, :race, :zip, :fork, :join, :cancel, :interrupt, :bracket, :ensuring, :sleep, :succeed, :fail, :attempt, :catch_error, :orelse, :getorelse, :foreach, :take, :drop, :collect, :first, :last, :head, :tail, :cons, :uncons, :ask, :tell, :get, :put, :modify, :pure, :ap, :sequence, :traverse, :both, :this, :that, :isnone, :issome, :isleft, :isright, :either, :maybe, :option, :Channel, :Timer, :Event, :schedule, :wait, :fetch, :yield, :Clock, :now,
]
for n in cands
    hits = [string(nameof(m)) for m in mods if isdefined(m, n) && Base.isexported(m, n)]
    isempty(hits) || println(rpad(string(n), 12), join(hits, ","))
end
