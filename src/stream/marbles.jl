# Marble testing on virtual time (ADR-0003 §9; phase-4 spec §13).

struct _MEvent
    frame::Int
    elems::Vector{Char}
    term::UInt8             # 0 none, 1 end, 2 failure
end

function _parsemarbles(spec::AbstractString)
    evs = _MEvent[]
    frame = 0
    ended = false
    cs = collect(spec)
    i = 1
    while i <= length(cs)
        c = cs[i]
        if c == ' '
            i += 1
            continue
        end
        ended && throw(ArgumentError("marbles: \"$spec\" has events after its end (`|` or `#`)"))
        if c == '('
            j = findnext(==(')'), cs, i)
            j === nothing && throw(ArgumentError("marbles: \"$spec\" has an unclosed group"))
            elems = Char[]
            term = 0x00
            for g in cs[(i + 1):(j - 1)]
                g == ' ' && continue
                term == 0x00 || throw(ArgumentError("marbles: \"$spec\": a group's end must be its last event"))
                if g == '|'
                    term = 0x01
                elseif g == '#'
                    term = 0x02
                elseif g == '-' || g == '('
                    throw(ArgumentError("marbles: \"$spec\": `$g` inside a group"))
                else
                    push!(elems, g)
                end
            end
            push!(evs, _MEvent(frame, elems, term))
            ended = term != 0x00
            i = j + 1
        elseif c == '-'
            i += 1
        elseif c == '|' || c == '#'
            push!(evs, _MEvent(frame, Char[], c == '|' ? 0x01 : 0x02))
            ended = true
            i += 1
        elseif c == ')'
            throw(ArgumentError("marbles: \"$spec\" has an unmatched `)`"))
        else
            push!(evs, _MEvent(frame, [c], 0x00))
            i += 1
        end
        frame += 1
    end
    return evs
end

struct _MarbleSrc
    events::Vector{_MEvent}
    values::Any
    error::Any
    frame::Float64
end
mutable struct _MarbleP <: _Puller
    s::_MarbleSrc
    t0::Float64
    seq::Int
    k::Int
    term::UInt8             # a terminal still to report
end
function _open(s::_MarbleSrc, ctx::_Ctx)
    c = _clockof(ctx)
    seq = c isa VirtualClock ? _reserveseq!(c, length(s.events)) : 0
    return _MarbleP(s, _now(c), seq, 0, 0x00)
end
_mvalue(values::Nothing, c::Char) = c
_mvalue(values, c::Char) = values[Symbol(c)]
_mterm(p::_MarbleP, t::UInt8) = t == 0x01 ? nothing : Fail(p.s.error)
function _pull!(p::_MarbleP, ctx::_Ctx)
    p.term == 0x00 || return _mterm(p, p.term)
    while true
        if p.k >= length(p.s.events)                   # no terminal: never ends (RxJS)
            _parkuntilcancel(ctx)
            return Interrupted()
        end
        p.k += 1
        ev = p.s.events[p.k]
        ok, c = _sleepuntil(ctx, p.t0 + ev.frame * p.s.frame, p.seq == 0 ? 0 : p.seq + p.k - 1)
        ok || return c
        if isempty(ev.elems)
            ev.term == 0x00 || return _mterm(p, ev.term)
            continue
        end
        p.term = ev.term
        return map(ch -> _mvalue(p.s.values, ch), ev.elems)
    end
    return
end
_close!(::_MarbleP, ::_Ctx) = nothing

"""
    ChuiTypes.marbles(spec; values = nothing, error = ErrorException("marble error"), frame = 1.0)

A cold marble source for tests on virtual time (phase-4 spec §13). One character is one frame of
`frame` seconds after the run subscribes: `-` an empty frame; any other character an element
(the `Char`, or `values[Symbol(c)]` with a `NamedTuple` `values`); `(…)` several elements, and
at most one end as the last, in **one** frame; `|` the end; `#` the failure `Fail(error)`;
spaces are ignored. Without `|` or `#` the stream never ends (as in RxJS).

On a [`VirtualClock`](@ref) the source reserves its timers' order when it is subscribed, so
same-instant events of several sources follow subscription order.
"""
function marbles(spec::AbstractString; values = nothing, error = ErrorException("marble error"), frame::Real = 1.0)
    evs = _parsemarbles(spec)
    T = values === nothing ? Char : mapreduce(typeof, typejoin, values; init = Union{})
    return _stream(T, _MarbleSrc(evs, values, error, Float64(frame)))
end

# Each element with the clock time its chunk was pulled at.
struct _StampSrc
    src::Any
end
struct _StampP <: _Puller
    up::Any
end
_open(s::_StampSrc, ctx::_Ctx) = _StampP(_sopen(s.src, ctx))
function _pull!(p::_StampP, ctx::_Ctx)
    r = _pull!(p.up, ctx)
    (r === nothing || r isa Cause) && return r
    t = _now(_clockof(ctx))
    return [(t, x) for x in r]
end
_close!(p::_StampP, ctx::_Ctx) = _close!(p.up, ctx)

function _mchar(x, names)
    names === nothing || return names[x]
    x isa Char && return x
    s = string(x)
    length(s) == 1 || throw(ArgumentError("marbletrace: the element $(repr(x)) does not print as one character; pass `names`"))
    return s[1]
end

function _render(log, term, tend, t0, frame, frames, names)
    byframe = Dict{Int, Vector{Char}}()
    for (t, x) in log
        f = round(Int, (t - t0) / frame)
        f < frames || continue
        push!(get!(byframe, f, Char[]), _mchar(x, names))
    end
    tf = term == 0x00 ? -1 : round(Int, (tend - t0) / frame)
    last = term == 0x00 ? frames - 1 : tf
    io = IOBuffer()
    for f in 0:last
        cs = copy(get(byframe, f, Char[]))
        f == tf && push!(cs, term == 0x01 ? '|' : '#')
        if isempty(cs)
            print(io, '-')
        elseif length(cs) == 1
            print(io, cs[1])
        else
            print(io, '(', String(cs), ')')
        end
    end
    return String(take!(io))
end

"""
    ChuiTypes.marbletrace(s; frame = 1.0, frames = 100, names = nothing) -> Effect{Any,String}

Run `s` and render what it emitted in the [`ChuiTypes.marbles`](@ref) grammar: each element at
frame `round(Int, (t - t0) / frame)` from the trace's start `t0`, its end as `|` and a failure as
`#`. Elements print as their one-character string, or as `names[x]`. A stream with no end
within `frames` frames is cut there (no terminal). Use it under [`runtest`](@ref).
"""
function marbletrace(s::Stream; frame::Real = 1.0, frames::Integer = 100, names = nothing)
    fr = Float64(frame)
    return defer() do
        log = Tuple{Float64, Any}[]
        rec = runforeach(tx -> push!(log, tx), _stream(Any, _StampSrc(s.src)))
        body = catchcause(c -> succeed(isinterrupted(c) ? 0x00 : 0x02), map(_ -> 0x01, rec))
        timed = racefirst(map(some, body), map(_ -> none(UInt8), delay(frames * fr)))
        andthen(clocktime()) do t0
            andthen(timed) do r
                map(clocktime()) do tend
                    term = get(r, 0x00)::UInt8
                    _render(log, term, tend, t0, fr, Int(frames), names)
                end
            end
        end
    end
end
