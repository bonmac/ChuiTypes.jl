# Hot sources: Subject (ADR-0003 §5; phase-4 spec §7). Virtual time, per-test clocks.

@testitem "Subject: late subscribers miss earlier emissions; close ends every subscription" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    subj = Subject{Int}()
    pub(xs...) = foldl((acc, x) -> andthen(_ -> publish(subj, x), acc), xs; init = succeed(nothing))
    prog = andthen(pub(1, 2)) do _                       # nobody subscribed: dropped
        andthen(fork(runcollect(subscribe(subj)))) do a
            andthen(delay(1.0)) do _
                andthen(pub(3, 4)) do _
                    andthen(fork(runcollect(subscribe(subj)))) do b
                        andthen(delay(1.0)) do _
                            andthen(pub(5)) do _
                                close(subj)
                                andthen(await(a)) do xa
                                    map(xb -> (ChuiTypes.value(xa), ChuiTypes.value(xb)), await(b))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    (v, c) = StreamHelpers.rt(prog)
    @test v == ([3, 4, 5], [5])
    @test StreamHelpers.settled(c) == 0
    # after close, a new subscription ends at once, and publish does nothing
    @test run(runcollect(subscribe(subj))) == Int[]
    @test run(publish(subj, 9)) === nothing
    # close with an exception fails subscribers with Fail(ex)
    s2 = Subject{Int}()
    err = ErrorException("hot")
    # (a supervised child's failure would fail the root scope: catch it in the child)
    prog2 = andthen(fork(catchcause(c -> succeed(c), map(_ -> nothing, runcollect(subscribe(s2)))))) do f
        andthen(_ -> (close(s2, err); map(ChuiTypes.value, await(f))), delay(1.0))
    end
    (c2, _) = StreamHelpers.rt(prog2)
    @test ChuiTypes.isfail(c2) && ChuiTypes.failure(c2) === err
    @test_throws ArgumentError Subject{Int}(; overflow = :bogus)
    @test_throws ArgumentError Subject{Int}(; capacity = 0)
end

@testitem "Subject: a consumer that keeps up sees every element; partial chunks" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    for p in (:block, :dropnewest, :dropoldest, :latest)
        subj = Subject{Int}(; capacity = 2, overflow = p)
        prog = andthen(fork(runchunks(subscribe(subj)))) do f
            andthen(delay(1.0)) do _          # subscribed and parked on an empty buffer
                pubs = foldl((acc, x) -> andthen(_ -> andthen(_ -> publish(subj, x), delay(1.0)), acc), 1:5; init = succeed(nothing))
                andthen(pubs) do _
                    close(subj)
                    map(x -> ChuiTypes.value(x), await(f))
                end
            end
        end
        (v, c) = StreamHelpers.rt(prog)
        @test v == [[1], [2], [3], [4], [5]]      # one partial chunk per emission
        @test StreamHelpers.settled(c) == 0
    end
end

@testitem "Subject: overflow with a consumer that does not keep up" tags = [:unit] setup = [StreamHelpers] begin
    using ChuiTypes
    using ChuiTypes: _register!, _unregister!, _buffered
    # Publish 5 elements into a subscriber buffer of capacity 2 while the subscriber is
    # registered but not pulling: the internal snapshot shows what each policy kept.
    for (p, kept) in ((:dropnewest, [1, 2]), (:dropoldest, [4, 5]), (:latest, [5]))
        subj = Subject{Int}(; capacity = 2, overflow = p)
        sub = _register!(subj)
        run(foldl((acc, x) -> andthen(_ -> publish(subj, x), acc), 1:5; init = succeed(nothing)))
        @test _buffered(sub) == kept
        _unregister!(subj, sub)
    end
    # :block: the publisher waits for space (cancellably): after 2 elements it parks
    subj = Subject{Int}(; capacity = 2, overflow = :block)
    sub = _register!(subj)
    f = start(foldl((acc, x) -> andthen(_ -> publish(subj, x), acc), 1:5; init = succeed(nothing)))
    sleep(0.05)
    @test f.exit === nothing && _buffered(sub) == [1, 2]
    interrupt!(f)
    StreamHelpers.waitfor(f)
    @test ChuiTypes.isinterrupted(ChuiTypes.cause(f.exit))
    _unregister!(subj, sub)
    # unregistering wakes a blocked publisher: it no longer waits for that subscriber
    sub2 = _register!(subj)
    g = start(foldl((acc, x) -> andthen(_ -> publish(subj, x), acc), 1:5; init = succeed(nothing)))
    sleep(0.05)
    _unregister!(subj, sub2)
    StreamHelpers.waitfor(g)
    @test ChuiTypes.succeeded(g.exit)
end

@testitem "Subject: a publish that cannot convert delivers to nobody" tags = [:unit] setup = [StreamHelpers] begin
    # review N8: the conversion ran per subscriber, after a :dropoldest eviction
    using ChuiTypes
    using ChuiTypes: _register!, _buffered, isdie, cause
    subj = Subject{Int}(; capacity = 1, overflow = :dropoldest)
    a, b = _register!(subj), _register!(subj)
    run(publish(subj, 1))
    @test isdie(cause(runexit(publish(subj, "x"))))
    @test _buffered(a) == [1] && _buffered(b) == [1]
    run(publish(subj, 2.0))                 # converts, as a typed container does
    @test _buffered(a) == [2] && _buffered(a)[1] isa Int
end
