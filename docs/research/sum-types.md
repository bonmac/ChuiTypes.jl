# Research: type-stable sum and option types

Date: 2026-10-20. Lane: phase1-research (ChuiTypes.jl). Question: which encoding of `Option`,
`Either`, `Validation`, `These`, `NonEmpty`, `LazyList` and the Reader/Writer/State/IO wrappers
keeps `map`, `flatmap` and `fold` inferred to a concrete type without allocating, on Julia 1.10
(the floor, ADR-0006) and current Julia?

## How verified

I ran every experiment on **Julia 1.13.2** (`julia +release`) and **Julia 1.10.12** (`julia +lts`),
each with its own scratch environment holding BenchmarkTools 1.8.0, SumTypes 0.5.9, Moshi 0.3.13,
LightSumTypes 5.2.2, MLStyle 0.4.17, ResultTypes 4.0.2, ErrorTypes 0.5.2, Expronicon 0.10.14 and
Unityper 0.1.6. All of them installed on both versions. Each run went through
`julia --startup-file=no scripts/evidence.jl <kind> -- <cmd>`, which wrote
`.lanes/evidence/<kind>-db74452.txt`. Every run exited 0. The files are gitignored, and their
`dirty: true` flag comes from other lanes' untracked files. The scripts live in the scratch
directory `/private/tmp/claude-501/-Users-bonmac-personal-projects-julia-data-analysis/5c1f011c-1151-4765-9a79-8eba6d64f4e6/scratchpad/types-p1/sumtypes/`
(called `$S` below):
`$S/option_bench.jl`, `$S/either_bench.jl`, `$S/misc_bench.jl`, `$S/state_depth.jl`,
`$S/base_check.jl`, `$S/mlstyle_check.jl`, `$S/registry_info.jl`.
Inference results come from `Base.return_types` on the input type that the constructing function
infers to, which is what a caller sees. Allocation results come from `@allocated` and from
BenchmarkTools' `allocs`. Timings are BenchmarkTools medians with `seconds = 2`.
**Caveat:** other lanes were running Julia on the same machine at the same time, so absolute times
are noisy (the same row moves by up to about 2x between reruns). Read the ratios and the
allocation counts, not the milliseconds. On 1.10, `@allocated` reports a constant 16 bytes for a
call made through a non-const global. That is a measurement artefact: BenchmarkTools reports
`allocs 0` for the same calls. Context7 has no index for any of the Julia packages (SUM-02), so
their facts come from the installed source, the General registry, GitHub and running code.

## 1. Prior art in other languages

| Language / library | Representation | Core operations |
|---|---|---|
| Scala 2.13 `Option` | `sealed abstract class Option[+A]`, `final case class Some[+A](value: A)`, `case object None extends Option[Nothing]` (subclassing; `None` is a single object typed `Option[Nothing]`) | `fold[B](ifEmpty: => B)(f: A => B)`, `map`, `flatMap`, `getOrElse` |
| cats `Validated` | `Valid(a)` and `Invalid(e)`. `ap` accumulates errors with `Semigroup[E].combine`, usually into a `NonEmptyChain` (`ValidatedNec`) | `ap`/`mapN` accumulate; there is no lawful `flatMap` |
| Haskell `base` 4.22 | `data Maybe a = Nothing \| Just a`, eliminated by `maybe :: b -> (a -> b) -> Maybe a -> b` | `fmap`, `>>=`, `maybe`/`either` |
| Haskell `these` 1.2.1 (2024-05-16) | `data These a b = This a \| That b \| These a b` | `these` fold, bifunctor |
| Rust std 1.99.1 | `enum Option<T>`. The null-pointer optimization guarantees `size_of::<Option<T>>() == size_of::<T>()` for `&U`, `Box<U>`, `NonZero*` and similar | `map`, `and_then`, `map_or`, `unwrap_or` |
| Purify (TS) | `Maybe`/`Either` objects with methods | `map`, `chain`, `caseOf({Left, Right})`, `orDefault`, `reduce` |
| daggy (JS) | `taggedSum('Option', {Some: ['x'], None: []})`, a tag on a prototype | `cata({Some: f, None: g})` |
| Monet.js | `Some`/`None`. `Some(null)` throws | `cata(noneFn, someFn)`, `fold(ifNone)(ifSome)` |
| Sanctuary Maybe v2.1.0 | `Maybe.Nothing :: Maybe a`, `Maybe.Just :: a -> Maybe a` | representation UNVERIFIED |
| Folktale `adt/union` | UNVERIFIED: the docs site did not resolve (ENOTFOUND) | — |

The common core across these libraries is the empty and full constructors, `map`, `flatMap`/`chain`, a two-handler
`fold`/`cata`/`caseOf`, and a default. Validation's accumulation is applicative (a semigroup on the
error side). Sources are listed in SUM-01.

## 2. Julia prior art

| Package | Representation (verified) | Deps | `julia` compat | Last push / latest tag |
|---|---|---|---|---|
| Base `Union{Nothing,T}`, `Some{T}` | a bare small union. Inline when the union is isbits (SUM-03) | 0 | — | — |
| SumTypes.jl | a concrete struct with one field `data::Union{Variant{:A,…},Variant{:B,…}}` (SUM-04) | MacroTools, PrecompileTools | 1.6 | 2026-09-03 / v0.5.9 |
| Moshi.jl `@data` | a concrete `Mod.Type{T}` struct with `data::Union{Storage#A{T},Storage#B{T}}`. The docs say "the Julia compiler is doing the rust-enum-like memory layout for `Union`s" | ExproniconLite, Jieko | 1.10 | 2026-09-27 / v0.3.13 |
| LightSumTypes.jl | a concrete struct with `variants::Union{…}` (src/LightSumTypes.jl:78). Its README recommends WrappedUnions.jl instead | MacroTools, PrecompileTools | 1.2 | 2026-10-18 / v5.2.2 |
| ErrorTypes.jl | `struct Result{O,E}; x::Union{Ok{O},Err{E}}; end`, `Option{T} = Result{T,Nothing}`. `and_then(f, T, x)` needs the output type spelled out | none | 1.3 | 2025-05-23 / v0.5.2 |
| ResultTypes.jl | `struct Result{T,E<:Exception}; result::Union{Some{T},Nothing}; error::Union{E,Nothing}; end` (two slots) | JuliaSyntax | 1.10 | 2025-11-10 / v4.0.2 |
| MLStyle.jl `@data` | an abstract supertype with one concrete struct per variant. It rejects a generic nullary variant (SUM-05) | none | 1 | 2025-09-09 / v0.4.17 |
| Expronicon `@adt` | one concrete isbits struct holding a tag field plus the flattened variant fields (SUM-05) | MLStyle | 1.6 | 2025-12-15 / v0.10.14 |
| Unityper.jl `@compactify` | one struct holding the union of all variants' fields (README) | ConstructionBase | 1.3 | 2023-12-20 / v0.1.6 |

Versions, compat and deps come from each installed package's `Project.toml` (`$S/registry_info.jl`).
Activity comes from `gh api repos/<owner>/<repo>` and `/tags`, read on 2026-10-20. Every package
supports Julia 1.10. "Maintenance status" here means only the last push date. Open issue counts and
bus factor are UNVERIFIED.

## 3. Experiments

Encodings for Option: **(a)** a tagged struct `TOpt{T}(isset::Bool, value::T)`, built with
`new{T}(false)` when empty so that `value` is left undefined; **(b)** a bare
`Union{BNone, BSome{T}}`; **(c)** an abstract `COpt{T}` with `CSome{T} <: COpt{T}` and
`CNone <: COpt{Union{}}`; **(e)** a wrapped union `WOpt{T}(x::Union{WNone, WSome{T}})`;
**(d1)** SumTypes; **(d2)** Moshi; **(f)** ErrorTypes. `map`, the 3-step `flatmap` and `fold`
compute the result type with `Core.Compiler.return_type` where the encoding needs it. Each vector
holds 10^6 options and about 50% are empty (`Random.seed!(1)`).

### SUM-01: prior-art sources
Scala: `raw.githubusercontent.com/scala/scala/2.13.x/src/library/scala/Option.scala` (fetched
2026-10-20). cats: Context7 `/typelevel/cats`, docs/datatypes/validated.md and
core/.../Validated.scala (`ap` uses `EE.combine`). Purify: Context7 `/gigobyte/purify`, the Either
interface. Haskell: `hackage-content.haskell.org/package/base-4.22.0.0/docs/Data-Maybe.html` and
`hackage.haskell.org/package/these` (1.2.1). Rust: `doc.rust-lang.org/std/option/index.html`
(std 1.99.1, the "Representation" section). daggy: `github.com/fantasyland/daggy` README. Monet:
`github.com/monet/monet.js/blob/master/docs/MAYBE.md`. Sanctuary:
`github.com/sanctuary-js/sanctuary-maybe` README.

### SUM-02: Context7 has no Julia sum-type packages
`resolve-library-id("SumTypes.jl")` returned only CUDA.jl, ForwardDiff.jl, Turing.jl and others.
`resolve-library-id("Moshi.jl")` returned the Square JSON library and Kyutai. I fell back to source.

### SUM-03: Base `Union{Nothing,T}` (evidence `sum-base-113`, `sum-base-110`, identical except the last line)
```
Union{Nothing, Int64}              allocatedinline=true  isbitsunion=true
Union{Nothing, String}             allocatedinline=false isbitsunion=false
Union{Int64, String}               allocatedinline=false isbitsunion=false
get(Dict(:a=>nothing), :a, nothing) === get(..., :b, nothing): true
2-step chain(::Union{Nothing,Int}) -> Union{Nothing, Int64}
@allocated ... 2-step chain = 0      (1.13.2)   = 16 (1.10.12, global-call artefact)
```
`nothing` cannot tell "absent" apart from "present and nothing", and the chain infers to a union
rather than a concrete type. The Julia devdocs page "isbits Union Optimizations" (1.13.2) says a
union is stored inline with one type-tag byte only when **all** its members are isbits.

### SUM-04: stored layout (evidence `sum-option-113`, `sum-option-110`, identical)
```
TOpt{Int64}   types=(Bool, Int64)                    isbits=true  inline=true  sizeof=16
WOpt{Int64}   types=(Union{WNone, WSome{Int64}},)    isbits=false inline=true  sizeof=16
SOpt{Int64}   types=(Union{SumTypes.Variant{:SNone,…},SumTypes.Variant{:SSome,…,Tuple{Int64}}},) inline=true sizeof=16
MOpt{Int64}   types=(Union{MOpt.##Storage#MNone{Int64}, MOpt.##Storage#MSome{Int64}},)    inline=true sizeof=16
TOpt{String}  types=(Bool, String)                   isbits=false inline=false sizeof=16
WOpt{String}  / SOpt{String} / MOpt{String}          inline=true  sizeof=8
```
SumTypes, Moshi and ErrorTypes all use encoding (e). The tagged struct (a) with an undefined field
is **not stored inline** when T is not isbits, so a `Vector{TOpt{String}}` holds pointers to boxes
(21.88 MiB against 18.07 MiB for (e)).

### SUM-05: MLStyle and Expronicon (evidence `sum-mlstyle-113`, `sum-mlstyle-110`, identical)
```
MLStyle generic nullary variant: LoadError: Defining generic enum GNone <: GOpt{T} is invalid, ...
MLStyle: isabstracttype(MLOpt)=true ... mk(::Bool) inferred Union{var"MLNone's constructor", MLSome}; comprehension eltype = MLOpt
Expronicon @adt: isconcretetype(EOpt)=true fieldtypes=(var"EOpt#Type", Int64) sizeof=16 isbitstype=true
```
MLStyle uses encoding (c) and cannot express `None` for a generic `Option{T}`.

### SUM-06: Option inference (evidence `sum-option-113`, `sum-option-110`, identical on both)
```
(a) mk -> TOpt{Int64}        map/3-step flatmap -> TOpt{Int64}    fold -> Int64   all concrete
(b) mk -> Union{BNone, BSome{Int64}}  map/flatmap -> same Union (concrete=false)  fold -> Int64
(c) mk -> Union{CNone, CSome{Int64}}  map/flatmap -> same Union (concrete=false)  fold -> Int64
(e) WOpt{Int64}, (d1) SOpt{Int64}, (d2) MOpt.Type{Int64}, (f) ErrorTypes.Option{Int64}: all concrete
```
Under (b) and (c), `fold` still infers to `Int64` because Julia union-splits the call. The
**values** stay unions, so any container or field that holds them is typed by whatever writes into
it (SUM-07).

### SUM-07: Option, a 10^6 vector, sum of `fold(0, identity, o)` and of the 3-step chain
Columns: medians in ms (sumfold / sumchain), `allocs` / bytes. Evidence: `sum-option-113` and `sum-option-110`.
```
                              1.13.2                          1.10.12
(a) tagged                    0.735 / 1.212   0 allocs        0.979 / 0.760   0 allocs
(b) comprehension -> Vector{Any}   43.4 / 59.7  1_499_740 allocs (24.0 MB)   33.1 / 44.1  same allocs
(b) typed Vector{Union{..}}   3.967 / 4.873   0 allocs        3.645 / 3.338   0 allocs
(c) comprehension -> Vector{COpt}  55.1 / 123.2 1_499_740 allocs            26.2 / 47.4  same allocs
(c) typed Vector{Union{..}}   5.705 / 6.379   0 allocs        3.221 / 3.218   0 allocs
(e) wrapped Union             0.501 / 4.846   0 allocs        0.346 / 3.949   0 allocs
(d1) SumTypes                 0.702 / 3.995   0 allocs        0.365 / 3.747   0 allocs
(d2) Moshi                    3.285 / 4.208   0 allocs        3.336 / 3.286   0 allocs
(f) ErrorTypes                0.434 / 3.955   0 allocs        0.358 / 3.075   0 allocs
String payload, sum of fold(0, length, o): every encoding 0 allocs, 6-18 ms (noise-dominated)
```
The comprehension `[cond ? some(i) : none(Int) for i ...]` widens under (b) to `Vector{Any}`
(`typejoin(BNone, BSome{Int}) == Any`) and under (c) to the abstract `Vector{COpt}`. The result
is about 1.5 boxed values per element and a 10-100x slowdown. The concrete-wrapper encodings
(a), (e), (d1), (d2) and (f) never widen.

### SUM-08: Either{String,Int}, inference and the cost of mixed payloads (evidence `sum-either-113`, `sum-either-110`)
Inference matches SUM-06 on both versions: (a), (e), (d1) and (d2) are concrete; (b) and (c) are a
`Union` and `fold` is `Int64`. Layout and the 10^6-element sum (50% `Left(MSG)` with one shared string):
```
                      sizeof  sumfold ms (1.13/1.10)  sumchain ms (1.13/1.10)  sumchain allocs
(a) tagged 2 slots      32      9.834 / 5.839          9.117 / 7.132            0
(b) typed Union         ptr     9.935 / 6.217          9.575 / 6.184            0
(c) typed Union         ptr    11.658 / 6.397          9.400 / 6.652            0
(e) wrapped Union        8      8.475 / 6.304         23.009 / 11.672           1_500_108 (24.0 MB)
(d1) SumTypes            8      8.216 / 6.280         22.236 / 18.623           3_000_000 (48.0 MB)
(d2) Moshi               8      8.305 / 6.071         41.616 / 13.734           3_000_000 (48.0 MB)
```
**This is the key negative result.** When one variant holds a pointer type (`String`) and the
other holds an isbits type (`Int`), the `Union` field is not an isbits union (SUM-03). So
SumTypes, Moshi and the hand-written (e) store a pointer to a box, and **every `Right` built in
the chain allocates**, on both versions. Encoding (a) gives each side its own slot
(`isright::Bool`, `l::Union{Nothing,L}`, `r::Union{Nothing,R}`). Each slot is then either a
pointer or an isbits union, so (a) is concrete, never allocates, and costs 32 bytes per element.
ResultTypes.jl uses the same two-slot layout.

### SUM-09: typed empty constructors (evidence `sum-misc-113`, `sum-misc-110`, identical)
```
f_typed(x)   = x > 0 ? some(x) : none(Int)          -> Opt{Int64}
f_untyped(x)::Opt{Int} = x > 0 ? some(x) : NONE     -> Opt{Int64}   (convert(::Type{Opt{T}}, ::NoneT))
f_bad(x)     = x > 0 ? some(x) : NONE               -> Union{NoneT, Opt{Int64}}
```
`none(T)` (equivalently `Option{T}()`) and `left(x, R)` are stable. An untyped singleton `NONE`
is stable only where a return annotation or a typed slot converts it. Moshi's `MNone{T}()`,
SumTypes' `SOpt{T}(SOpt'.SNone)` and ErrorTypes' `none(T)` all require the type.

### SUM-10: Validation accumulation (evidence `sum-misc-113`, `sum-misc-110`)
```
both(x) = vzip(check_pos(x), check_even(x))  -> Validation{String, Tuple{Int64, Int64}} (concrete)
Validation{String,Int} sizeof=8 (boxed Union, as in SUM-08)
@allocated both(2)  (valid,valid)    = 64 (1.13.2)   0 (1.10.12)
@allocated both(-3) (invalid,invalid)= 256 (1.13.2)  304 (1.10.12)
tuple accumulation errs_tuple(x) -> Union{Tuple{}, Tuple{String}, Tuple{String, String}}
```
Errors kept as a `Vector{E}` (a semigroup under `vcat`/`append!`) keep the type concrete and
allocate only on the failure path. Errors kept as a growing `Tuple` change type with the error
count and are not stable. The 64 B on the valid path under 1.13 comes from boxing the mixed
`Union` field, the same cause as SUM-08. A two-slot layout for Validation was **not measured**
(UNVERIFIED).

### SUM-11: NonEmpty (evidence `sum-misc-113`, `sum-misc-110`)
`struct NonEmpty{T}; head::T; tail::Vector{T}; end`: `map` infers to `NonEmpty{Int64}` and
`n.head` infers to `Int64` on both versions.

### SUM-12: State as a closure struct (evidence `sum-state-113`, `sum-state-110`, identical)
```
struct State{F}; run::F; end ; st_flatmap(f, m) = State(s -> ((a, s2) = m.run(s); f(a).run(s2)))
depth 1: run(::Int) -> Tuple{Int64, Int64}  @allocated=0
depth 2: run(::Int) -> Tuple{Int64, Int64}  @allocated=0
depth 3: run(::Int) -> Any  @allocated=48
```
`State{F}` has a concrete type, but at three nested `flatmap`s inference returns `Any` on both
versions. The cause is probably recursion limiting on the nested closure types, which is
UNVERIFIED. With the erased `run::Function` field, `run` infers to `Tuple{Any,Any}`
(`sum-misc-*`). Reader and Writer were not measured but have the same shape (UNVERIFIED). IO was
not measured.

### SUM-13: LazyList with thunk tails (evidence `sum-misc-113`, `sum-misc-110`)
```
Lazy{T}(cell::Union{LNil, Tuple{T, Function}})   lsum -> Int64
@allocated lsum(lrange(1,10^4)) = 951792 (1.13.2) / 951808 (1.10.12)   (~95 B per element)
median lsum 378 us vs sum on a Vector 0.66 us (1.13.2); 288 us vs 1.08 us (1.10.12)
```
The fold infers concretely only because of the `::Lazy{T}` assertion on each forced tail. Each
step allocates a closure and a cell, about 300-600x slower than a `Vector`.

## 4. Recommendation

The ADR should require **every value type to be a concrete parametric struct** whose type
parameters fix the payload types. It should reject the bare `Union` (b) and abstract-supertype (c)
encodings, including MLStyle `@data`. Under (b) and (c), `map` and `flatmap` return unions
(SUM-06), and an ordinary comprehension widens to `Vector{Any}` or `Vector{<:Abstract}` with about
1.5 allocations per element and a 10-100x slowdown (SUM-07). For **Option** use the wrapped union
`struct Option{T}; x::Union{None, Some{T}}; end`. It is concrete, stored inline, allocation-free
and among the fastest rows for both `Int` and `String` payloads on 1.10.12 and 1.13.2
(SUM-04, SUM-07). It is the same layout SumTypes, Moshi and ErrorTypes generate, so it needs no
dependency. For **Either, Validation and These**, whose two sides commonly mix pointer and isbits
types, use the **two-slot tagged layout** `(tag, l::Union{Nothing,L}, r::Union{Nothing,R})`. That
is the only encoding measured that stays concrete and allocation-free for `Either{String,Int}`
chains, where wrapped unions, SumTypes and Moshi allocate 1.5-3 M times per 10^6 elements
(SUM-08). These maps naturally onto a 3-valued tag with both slots set. Empty and left
constructors take the missing type: `none(T)`, `Option{T}()`, `left(x, R)` (SUM-09). Validation
accumulates errors in a `Vector{E}` or a caller-supplied semigroup, never a tuple (SUM-10). Do not
depend on SumTypes, Moshi or MLStyle: about 20 hand-written lines match their speed, and two of the
three bring two dependencies each (Section 2). Closure-based State/Reader/Writer stop inferring
concretely at depth 3 (SUM-12), and thunk LazyLists allocate per element (SUM-13). The effects and
streams ADRs need their own designs for those (for example a fused interpreter, or iterator-based
streams), not a reuse of this encoding.

## UNVERIFIED

- The internal representation of Folktale `adt/union` (site unreachable) and of Sanctuary Maybe.
- A two-slot Validation and These: inference and allocations were not measured; the claim extrapolates from SUM-08.
- The cause of State losing inference at depth 3 (recursion limiting is suspected); Reader, Writer and IO were not measured.
- Maintenance beyond the last push and tag dates (issues, maintainers).
- WrappedUnions.jl, which LightSumTypes' README recommends, was not installed or measured.
- Why the valid-path `both(2)` allocates 64 B on 1.13.2 but 0 B on 1.10.12.
