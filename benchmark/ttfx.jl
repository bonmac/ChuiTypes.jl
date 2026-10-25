# Time to first X (spec 2026-10-26-phase5-performance-design.md §4 T4): fresh-process load time
# and per-entry first-call times of a representative workload, repeated N times.
#
#   julia --project=. benchmark/ttfx.jl [--reps N] [--compilecache K]
#
# Each repetition is a new `julia` (`Base.julia_cmd()`, so the child has this process's flags,
# e.g. `--check-bounds=yes` under Pkg.test, and so its package cache) with this process's active
# project. One warm-up repetition runs first and is discarded (it warms the OS file cache and
# makes sure the package image exists). Prints every repetition, then median, min and max per
# entry, and the load average before and after. `--compilecache K` also times K fresh
# `Base.compilecache` runs (the cost of building the package image, workload included).
# Machine-readable lines start with `RESULT` (one repetition) and `SUMMARY` (min and median of
# the total); test/test_precompile.jl parses `SUMMARY`.
#
# The workload entries are closures defined in the child, so they are new types there: what a
# precompile workload can save is the compilation of the package's own methods they reach.

function median(v)                             # no Statistics: the script runs in the package's own project
    s = sort(v)
    n = length(s)
    return isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2
end

const CHILD = raw"""
t_load = @elapsed using ChuiTypes
const U = ChuiTypes.Upstream
const WORKLOAD = [
    "option" => () -> foldl(+, U.chain(x -> x > 0 ? some(x - 1) : none(Int), map(x -> x + 1, some(3))); init = 0),
    "either" => () -> foldl(+, U.chain(x -> x > 0 ? right(String, x - 1) : left("neg", Int), map(x -> x + 1, right(String, 3))); init = 0),
    "andthen" => () -> run(andthen(x -> succeed(x + 1), succeed(1))),
    "collect_filter_map" => () -> run(runcollect(filter(iseven, map(x -> x + 1, fromiter(1:1000))))),
    "fold_map" => () -> run(runfold(+, 0, map(x -> x + 1, fromiter(1:1000)))),
    "merge" => () -> run(runcollect(merge(fromiter(1:10), fromiter(1:10)))),
    "state" => () -> runstate(andthen(_ -> modifystate(x -> x * 2, Int), andthen(x -> putstate(Int, x + 1), getstate(Int))), 1),
    "fork_await" => () -> run(andthen(f -> await(f), fork(succeed(5)))),
]
out = String["load=$(round(t_load; digits = 4))"]
total = 0.0
for (name, f) in WORKLOAD
    local t = @elapsed f()
    global total += t
    push!(out, "$name=$(round(t; digits = 4))")
end
push!(out, "total=$(round(total; digits = 4))")
println("RESULT ", join(out, " "))
"""

const COMPILECACHE = raw"""
t = @elapsed Base.compilecache(Base.identify_package("ChuiTypes"))
println("RESULT compilecache=$(round(t; digits = 3))")
"""

loadavg() =
try
    strip(read(`uptime`, String))
catch err
    "uptime unavailable ($(sprint(showerror, err)))"
end

child(code) = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`

"Run `code` in a fresh process; the `key=value` pairs of its `RESULT` line, in order."
function runchild(code)
    out = read(child(code), String)
    i = findlast("RESULT ", out)
    i === nothing && error("no RESULT line from the child:\n$out")
    line = first(split(out[(last(i) + 1):end], '\n'))
    return [(String(k), parse(Float64, v)) for (k, v) in split.(split(line), '=')]
end

function parseargs(args)
    reps, cc = 7, 0
    i = 1
    while i <= length(args)
        a = args[i]
        a == "--reps" ? (reps = parse(Int, args[i + 1]); i += 2) :
            a == "--compilecache" ? (cc = parse(Int, args[i + 1]); i += 2) :
            error("unknown argument $(repr(a)); usage: ttfx.jl [--reps N] [--compilecache K]")
    end
    reps >= 1 || error("--reps must be >= 1")
    return reps, cc
end

function main(args)
    reps, cc = parseargs(args)
    println("uptime-start: ", loadavg())
    println("julia ", VERSION, " threads=", Threads.nthreads(), " ", Sys.MACHINE, " ", Sys.cpu_info()[1].model)
    println("cmd: ", child("…"))
    runchild(CHILD)                                # warm-up, discarded
    rows = [runchild(CHILD) for _ in 1:reps]
    for r in rows
        println("RESULT ", join(("$k=$v" for (k, v) in r), " "))
    end
    println("entry                 median      min      max   (s, n = $reps)")
    for j in eachindex(first(rows))
        name = first(rows)[j][1]
        v = [r[j][2] for r in rows]
        println(rpad(name, 20), " ", lpad(round(median(v); digits = 4), 8), " ", lpad(minimum(v), 8), " ", lpad(maximum(v), 8))
    end
    totals = [last(r)[2] for r in rows]
    println("SUMMARY reps=$reps min_total=$(minimum(totals)) median_total=$(median(totals)) max_total=$(maximum(totals))")
    if cc > 0
        t = [only(runchild(COMPILECACHE))[2] for _ in 1:cc]
        println("compilecache: ", join(t, " "), "  median=$(median(t)) (s, n = $cc)")
    end
    println("uptime-end: ", loadavg())
    return nothing
end

abspath(PROGRAM_FILE) == @__FILE__() && main(ARGS)
