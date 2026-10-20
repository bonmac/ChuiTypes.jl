# Reader, Writer and State share one erased node layout and one interpreter (ADR-0007).
#
# A program is a tree of `_RNode`s: a `UInt8` tag and two untyped payloads. The public
# wrappers (`Reader{R}`, `Writer{W}`, `State{S}`) hold one node and fix the declared parameter;
# the success type is not a parameter. `_rwsrun` walks the tree with an explicit frame stack,
# so neither bind depth nor the nesting depth of the scoped operations (`withreader`,
# `listening`, `censor`) uses the Julia call stack.
#
# The node is a `mutable struct` whose fields are all `const`: it is never mutated, but its
# identity is its address. With an immutable node, `===` and `hash` on two separately built
# deep programs recurse through the whole tree and overflow the stack at 10^6 nodes (both
# 1.10 and 1.13); with this layout they are O(1) identity (ADR-0007 §5: no `==` methods).

const _R_PURE = 0x00    # a: the value
const _R_BIND = 0x01    # a: inner node, b: continuation (value -> wrapper of the same type)
const _R_MAP = 0x02     # a: inner node, b: function (value -> value)
const _R_ASK = 0x03     # Reader: the environment
const _R_LOCAL = 0x04   # Reader: a: inner node, b: environment function
const _R_TELL = 0x05    # Writer: a: the log entry
const _R_LISTEN = 0x06  # Writer: a: inner node
const _R_CENSOR = 0x07  # Writer: a: inner node, b: log function
const _R_GET = 0x08     # State: the state
const _R_PUT = 0x09     # State: a: the new state (already converted to S)
const _R_MODIFY = 0x0a  # State: b: state function

mutable struct _RNode
    const tag::UInt8
    const a::Any
    const b::Any
end

# Frames of the explicit stack.
const _RF_BIND = 0x00    # f: continuation
const _RF_MAP = 0x01     # f: function
const _RF_ENV = 0x02     # saved: the environment to restore
const _RF_LISTEN = 0x03  # saved: the outer log
const _RF_CENSOR = 0x04  # f: log function, saved: the outer log

struct _RFrame
    tag::UInt8
    f::Any
    saved::Any
end

# Reader and State runs have no monoid; their programs never hold Writer nodes.
struct _NoMonoid end
_rneutral(m) = Upstream.neutral(m)
_rneutral(::_NoMonoid) = nothing
_rcombine(m, a, b) = Upstream.combine(m, a, b)
_rcombine(::_NoMonoid, a, b) = nothing

@noinline _wrongkind(::Type{M}, x) where {M} = throw(
    ArgumentError("andthen: a continuation of a $M returned a $(typeof(x)); it must return a $M")
)

"""
    _rwsrun(node, M, R, S, W, r0, s0, mon, w0) -> (a, s::S, w::W)

Runs the program `node` of wrapper type `M` with environment `r0` (converted to `R`), state
`s0` (converted to `S`) and log `w0` (converted to `W`), combining log entries with `mon`.
Every continuation's result must be an `M`, else an `ArgumentError` naming both types.
"""
function _rwsrun(
        node::_RNode, ::Type{M}, ::Type{R}, ::Type{S}, ::Type{W}, r0, s0, mon, w0
    ) where {M, R, S, W}
    r::R = r0
    s::S = s0
    w::W = w0
    stack = _RFrame[]
    cur = node
    while true
        local a
        t = cur.tag
        # descend: push a frame and run the inner node
        if t == _R_BIND
            push!(stack, _RFrame(_RF_BIND, cur.b, nothing))
            cur = cur.a::_RNode
            continue
        elseif t == _R_MAP
            push!(stack, _RFrame(_RF_MAP, cur.b, nothing))
            cur = cur.a::_RNode
            continue
        elseif t == _R_LOCAL
            push!(stack, _RFrame(_RF_ENV, nothing, r))
            r = cur.b(r)
            cur = cur.a::_RNode
            continue
        elseif t == _R_LISTEN
            push!(stack, _RFrame(_RF_LISTEN, nothing, w))
            w = _rneutral(mon)
            cur = cur.a::_RNode
            continue
        elseif t == _R_CENSOR
            push!(stack, _RFrame(_RF_CENSOR, cur.b, w))
            w = _rneutral(mon)
            cur = cur.a::_RNode
            continue
            # leaves: produce a value
        elseif t == _R_PURE
            a = cur.a
        elseif t == _R_ASK
            a = r
        elseif t == _R_TELL
            w = _rcombine(mon, w, cur.a)
            a = nothing
        elseif t == _R_GET
            a = s
        elseif t == _R_PUT
            s = cur.a
            a = nothing
        else # _R_MODIFY
            s = cur.b(s)
            a = nothing
        end
        # ascend: pop frames until a continuation gives the next node
        while true
            isempty(stack) && return (a, s, w)
            fr = pop!(stack)
            ft = fr.tag
            if ft == _RF_BIND
                m = fr.f(a)
                m isa M || _wrongkind(M, m)
                cur = (m::M).node
                break
            elseif ft == _RF_MAP
                a = fr.f(a)
            elseif ft == _RF_ENV
                r = fr.saved
            elseif ft == _RF_LISTEN
                inner = w
                w = _rcombine(mon, fr.saved, inner)
                a = (a, inner)
            else # _RF_CENSOR
                w = _rcombine(mon, fr.saved, fr.f(w))
            end
        end
    end
    return
end

# Shared node builders for the three wrappers.
_bindnode(k, node::_RNode) = _RNode(_R_BIND, node, k)
_mapnode(f, node::_RNode) = _RNode(_R_MAP, node, f)
_purenode(x) = _RNode(_R_PURE, x, nothing)
# `ap(ff, fx)`: run `ff`, then `fx`, then apply (the effects of `ff` come first).
_apnode(::Type{M}, ff::M, fx::M) where {M} = _bindnode(f -> M(_NEW, _mapnode(f, fx.node)), ff.node)
