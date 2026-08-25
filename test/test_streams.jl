@testitem "eof(stream) - cancel is non-destructive" setup=[SpawnHelper] begin
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)

    src = CancellationTokenSource()
    token = get_token(src)

    @spawn begin
        sleep(0.2)
        cancel(src)
    end

    @test_throws OperationCanceledException eof(pipe.out, token)

    # the stream must be fully usable after the cancelled wait
    @test isopen(pipe.out)
    write(pipe, "late data\n")
    src2 = CancellationTokenSource(10.0)
    @test eof(pipe.out, get_token(src2)) == false
    @test readline(pipe) == "late data"

    close(pipe)
end

@testitem "eof(stream) - data already available" begin
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
    write(pipe, "x")

    src = CancellationTokenSource()
    @test eof(pipe.out, get_token(src)) == false

    # an already-cancelled token throws before anything else (level-triggered
    # entry check), even when data is available
    cancel(src)
    @test_throws OperationCanceledException eof(pipe.out, get_token(src))

    close(pipe)
end

@testitem "eof(stream) - blocks until data arrives" setup=[SpawnHelper] begin
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)

    @spawn begin
        sleep(0.2)
        write(pipe, "arrived")
    end

    src = CancellationTokenSource(10.0)
    @test eof(pipe.out, get_token(src)) == false
    @test String(readavailable(pipe.out)) == "arrived"

    close(pipe)
end

@testitem "eof(stream) - end of stream" setup=[SpawnHelper] begin
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)

    write(pipe, "tail")
    close(pipe.in)   # writer done

    src = CancellationTokenSource(10.0)
    token = get_token(src)
    @test eof(pipe.out, token) == false      # buffered data first
    @test String(readavailable(pipe.out)) == "tail"
    @test eof(pipe.out, token) == true       # then a true EOF, no throw

    close(pipe)
end

@testitem "eof(stream) - concurrent Base reader is unaffected" setup=[SpawnHelper] begin
    # A cancelled waiter must not disturb another task's plain blocking read
    # on the same stream (the wake of the shared condition is spurious for
    # Base's reader, which re-checks and keeps waiting).
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)

    reader = @spawn readline(pipe)

    src = CancellationTokenSource()
    token = get_token(src)
    canceller = @spawn begin
        sleep(0.2)
        cancel(src)
    end
    @test_throws OperationCanceledException eof(pipe.out, token)
    wait(canceller)

    @test !istaskdone(reader)     # still blocked, still healthy
    write(pipe, "for the reader\n")
    @test fetch(reader) == "for the reader"

    close(pipe)
end
