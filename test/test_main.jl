# ---------------------------------------------------------------------------
# CancellationTokenSource — construction and state
# ---------------------------------------------------------------------------

@testitem "CancellationTokenSource starts in non-cancelled state" begin
    src = CancellationTokenSource()
    @test !is_cancellation_requested(src)
end

@testitem "cancel sets is_cancellation_requested" begin
    src = CancellationTokenSource()
    cancel(src)
    @test is_cancellation_requested(src)
end

@testitem "cancel is idempotent" begin
    src = CancellationTokenSource()
    cancel(src)
    cancel(src)
    cancel(src)
    @test is_cancellation_requested(src)
end

@testitem "close cancels the source" begin
    src = CancellationTokenSource()
    close(src)
    @test is_cancellation_requested(src)
end

# ---------------------------------------------------------------------------
# CancellationToken — get_token and is_cancellation_requested
# ---------------------------------------------------------------------------

@testitem "get_token returns a token that supports is_cancellation_requested" begin
    src = CancellationTokenSource()
    token = get_token(src)
    @test !is_cancellation_requested(token)
end

@testitem "Token reflects source cancellation state" begin
    src = CancellationTokenSource()
    token = get_token(src)
    @test !is_cancellation_requested(token)
    cancel(src)
    @test is_cancellation_requested(token)
end

@testitem "Multiple tokens from the same source share state" begin
    src = CancellationTokenSource()
    t1 = get_token(src)
    t2 = get_token(src)
    cancel(src)
    @test is_cancellation_requested(t1)
    @test is_cancellation_requested(t2)
end

# ---------------------------------------------------------------------------
# wait(::CancellationToken)
# ---------------------------------------------------------------------------

@testitem "wait returns immediately when already cancelled" begin
    src = CancellationTokenSource()
    cancel(src)
    # Should not block
    wait(get_token(src))
    @test true
end

@testitem "wait blocks until cancel is called" begin
    src = CancellationTokenSource()
    token = get_token(src)
    done = Ref(false)

    @async begin
        sleep(0.1)
        cancel(src)
    end

    wait(token)
    done[] = true
    @test done[]
    @test is_cancellation_requested(src)
end

@testitem "wait returns immediately when cancelled before wait but after token creation" begin
    src = CancellationTokenSource()
    token = get_token(src)
    cancel(src)
    wait(token)
    @test true
end

@testitem "Multiple waiters all unblock on cancel" begin
    src = CancellationTokenSource()
    token = get_token(src)
    results = Channel{Int}(10)

    for i in 1:5
        @async begin
            wait(token)
            put!(results, i)
        end
    end

    sleep(0.05)
    cancel(src)
    sleep(0.1)

    collected = Int[]
    while isready(results)
        push!(collected, take!(results))
    end
    @test sort(collected) == [1, 2, 3, 4, 5]
end

# ---------------------------------------------------------------------------
# CancellationTokenSource with timeout
# ---------------------------------------------------------------------------

@testitem "Timeout source cancels after specified duration" begin
    src = CancellationTokenSource(0.1)
    @test !is_cancellation_requested(src)
    wait(get_token(src))
    @test is_cancellation_requested(src)
end

@testitem "Timeout source can be cancelled early" begin
    src = CancellationTokenSource(10.0)
    @test !is_cancellation_requested(src)
    cancel(src)
    @test is_cancellation_requested(src)
end

@testitem "Timeout source - wait returns after timeout" begin
    t0 = time()
    src = CancellationTokenSource(0.1)
    wait(get_token(src))
    elapsed = time() - t0
    @test elapsed >= 0.05
    @test elapsed < 2.0
end

# ---------------------------------------------------------------------------
# Combined CancellationTokenSource
# ---------------------------------------------------------------------------

@testitem "Combined source cancels when first token cancels" begin
    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2))

    @test !is_cancellation_requested(combined)
    cancel(src1)
    sleep(0.05)
    @test is_cancellation_requested(combined)
end

@testitem "Combined source cancels when second token cancels" begin
    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2))

    cancel(src2)
    sleep(0.05)
    @test is_cancellation_requested(combined)
    # src1 should not be affected
    @test !is_cancellation_requested(src1)
end

@testitem "Combined source - wait unblocks on any parent cancel" begin
    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2))

    @async begin
        sleep(0.1)
        cancel(src2)
    end

    wait(get_token(combined))
    @test is_cancellation_requested(combined)
    @test !is_cancellation_requested(src1)
    @test is_cancellation_requested(src2)
end

@testitem "Combined source with already-cancelled token cancels immediately" begin
    src1 = CancellationTokenSource()
    cancel(src1)
    src2 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2))

    sleep(0.05)
    @test is_cancellation_requested(combined)
end

@testitem "Combined source with single token" begin
    src = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src))

    @test !is_cancellation_requested(combined)
    cancel(src)
    sleep(0.05)
    @test is_cancellation_requested(combined)
end

@testitem "Combined source with three tokens" begin
    src1 = CancellationTokenSource()
    src2 = CancellationTokenSource()
    src3 = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(src1), get_token(src2), get_token(src3))

    cancel(src3)
    sleep(0.05)
    @test is_cancellation_requested(combined)
    @test !is_cancellation_requested(src1)
    @test !is_cancellation_requested(src2)
end

@testitem "Combined source with timeout token" begin
    timeout_src = CancellationTokenSource(0.1)
    manual_src = CancellationTokenSource()
    combined = CancellationTokenSource(get_token(timeout_src), get_token(manual_src))

    wait(get_token(combined))
    @test is_cancellation_requested(combined)
    @test is_cancellation_requested(timeout_src)
    @test !is_cancellation_requested(manual_src)
end

# ---------------------------------------------------------------------------
# OperationCanceledException
# ---------------------------------------------------------------------------

@testitem "OperationCanceledException carries the token" begin
    src = CancellationTokenSource()
    token = get_token(src)
    ex = OperationCanceledException(token)
    @test ex isa Exception
    @test get_token(ex) === token
end

@testitem "OperationCanceledException is a subtype of Exception" begin
    @test OperationCanceledException <: Exception
end
