# ---------------------------------------------------------------------------
# Base.sleep with cancellation token
# ---------------------------------------------------------------------------

@testitem "sleep completes normally without cancellation" begin
    src = CancellationTokenSource()
    t0 = time()
    sleep(0.1, get_token(src))
    elapsed = time() - t0
    @test elapsed >= 0.05
    @test !is_cancellation_requested(src)
end

@testitem "sleep throws OperationCanceledException on cancel" begin
    src = CancellationTokenSource()
    @async begin
        sleep(0.1)
        cancel(src)
    end
    @test_throws OperationCanceledException sleep(20.0, get_token(src))
end

@testitem "sleep - exception carries the correct token" begin
    src = CancellationTokenSource()
    token = get_token(src)
    @async begin
        sleep(0.1)
        cancel(src)
    end
    try
        sleep(20.0, token)
        @test false  # should not reach here
    catch ex
        @test ex isa OperationCanceledException
        @test get_token(ex) === token
    end
end

@testitem "sleep - cancel before sleep throws immediately" begin
    src = CancellationTokenSource()
    cancel(src)
    @test_throws OperationCanceledException sleep(20.0, get_token(src))
end

@testitem "sleep - cancellation returns faster than timeout" begin
    src = CancellationTokenSource()
    @async begin
        sleep(0.1)
        cancel(src)
    end
    t0 = time()
    try
        sleep(60.0, get_token(src))
    catch ex
        @test ex isa OperationCanceledException
    end
    elapsed = time() - t0
    @test elapsed < 5.0
end

@testitem "sleep - zero duration completes immediately" begin
    src = CancellationTokenSource()
    sleep(0.0, get_token(src))
    @test !is_cancellation_requested(src)
end

# ---------------------------------------------------------------------------
# Base.wait(::Channel, ::CancellationToken)
# ---------------------------------------------------------------------------

@testitem "wait(Channel) returns when channel becomes ready" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(1)
    @async begin
        sleep(0.1)
        put!(ch, 42)
    end
    wait(ch, get_token(src))
    @test isready(ch)
    @test !is_cancellation_requested(src)
end

@testitem "wait(Channel) throws on cancellation" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(1)
    @async begin
        sleep(0.1)
        cancel(src)
    end
    @test_throws OperationCanceledException wait(ch, get_token(src))
end

@testitem "wait(Channel) returns immediately if channel already has data" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(1)
    put!(ch, 1)
    wait(ch, get_token(src))
    @test true
end

@testitem "wait(Channel) throws immediately if already cancelled" begin
    src = CancellationTokenSource()
    cancel(src)
    ch = Channel{Int}(1)
    @test_throws OperationCanceledException wait(ch, get_token(src))
end

@testitem "wait(Channel) exception carries correct token" begin
    src = CancellationTokenSource()
    token = get_token(src)
    ch = Channel{Int}(1)
    @async begin
        sleep(0.1)
        cancel(src)
    end
    try
        wait(ch, token)
        @test false
    catch ex
        @test ex isa OperationCanceledException
        @test get_token(ex) === token
    end
end

@testitem "wait(Channel) - closed channel throws" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(1)
    close(ch)
    @test_throws InvalidStateException wait(ch, get_token(src))
end

# ---------------------------------------------------------------------------
# Base.take!(::Channel, ::CancellationToken) — buffered
# ---------------------------------------------------------------------------

@testitem "take!(Channel) returns value when data available" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    put!(ch, 42)
    v = take!(ch, get_token(src))
    @test v == 42
end

@testitem "take!(Channel) blocks and returns when data arrives" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    @async begin
        sleep(0.1)
        put!(ch, 99)
    end
    v = take!(ch, get_token(src))
    @test v == 99
end

@testitem "take!(Channel) throws on cancellation" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(Inf)
    @async begin
        sleep(0.1)
        cancel(src)
    end
    @test_throws OperationCanceledException take!(ch, get_token(src))
end

@testitem "take!(Channel) throws immediately if already cancelled" begin
    src = CancellationTokenSource()
    cancel(src)
    ch = Channel{Int}(Inf)
    put!(ch, 1)
    # Even though data is available, the token is already cancelled
    @test_throws OperationCanceledException take!(ch, get_token(src))
end

@testitem "take!(Channel) exception carries correct token" begin
    src = CancellationTokenSource()
    token = get_token(src)
    ch = Channel{Int}(Inf)
    @async begin
        sleep(0.1)
        cancel(src)
    end
    try
        take!(ch, token)
        @test false
    catch ex
        @test ex isa OperationCanceledException
        @test get_token(ex) === token
    end
end

@testitem "take!(Channel) preserves FIFO order" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    for i in 1:5
        put!(ch, i)
    end
    for i in 1:5
        @test take!(ch, get_token(src)) == i
    end
end

@testitem "take!(Channel) - closed empty channel throws" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    close(ch)
    @test_throws InvalidStateException take!(ch, get_token(src))
end

@testitem "take!(Channel) - closed channel with remaining data returns data" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    put!(ch, 1)
    put!(ch, 2)
    close(ch)
    @test take!(ch, get_token(src)) == 1
    @test take!(ch, get_token(src)) == 2
    @test_throws InvalidStateException take!(ch, get_token(src))
end

@testitem "take!(Channel) on unbuffered channel throws not-implemented" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(0)
    @test_throws ErrorException take!(ch, get_token(src))
end

@testitem "take!(Channel) - channel usable after cancelled take!" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)

    @async begin
        sleep(0.1)
        cancel(src)
    end
    @test_throws OperationCanceledException take!(ch, get_token(src))

    # Channel should still work normally
    put!(ch, 42)
    @test take!(ch) == 42
end

@testitem "take!(Channel) with typed channel" begin
    src = CancellationTokenSource()
    ch = Channel{String}(10)
    put!(ch, "hello")
    v = take!(ch, get_token(src))
    @test v == "hello"
    @test v isa String
end

@testitem "take!(Channel) - multiple sequential takes with token" begin
    src = CancellationTokenSource()
    ch = Channel{Int}(10)
    @async begin
        for i in 1:3
            sleep(0.05)
            put!(ch, i)
        end
    end
    results = [take!(ch, get_token(src)) for _ in 1:3]
    @test results == [1, 2, 3]
end
