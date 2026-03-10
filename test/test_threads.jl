# ---------------------------------------------------------------------------
# Thread safety tests — exercise concurrent cancel/wait patterns.
# These tests are meaningful with multiple threads (julia -t4) but should
# also pass on a single thread.
# ---------------------------------------------------------------------------

@testitem "Concurrent cancel and wait" begin
    for _ in 1:50
        src = CancellationTokenSource()
        token = get_token(src)
        waiters = [Threads.@spawn(wait(token)) for _ in 1:4]
        Threads.@spawn cancel(src)
        for w in waiters
            wait(w)
        end
        @test is_cancellation_requested(src)
    end
end

@testitem "Race between cancel and wait" begin
    for _ in 1:50
        src = CancellationTokenSource()
        token = get_token(src)
        t1 = Threads.@spawn wait(token)
        t2 = Threads.@spawn cancel(src)
        wait(t1)
        wait(t2)
        @test is_cancellation_requested(src)
    end
end

@testitem "Concurrent is_cancellation_requested reads" begin
    src = CancellationTokenSource()
    token = get_token(src)
    results = Vector{Bool}(undef, 100)

    cancel(src)

    tasks = [Threads.@spawn(is_cancellation_requested(token)) for _ in 1:100]
    for (i, t) in enumerate(tasks)
        results[i] = fetch(t)
    end
    @test all(results)
end

@testitem "Concurrent take! cancellation" begin
    for _ in 1:20
        src = CancellationTokenSource()
        ch = Channel{Int}(Inf)
        t = Threads.@spawn begin
            sleep(0.01)
            cancel(src)
        end
        @test_throws OperationCanceledException take!(ch, get_token(src))
        wait(t)
    end
end

@testitem "Concurrent wait(Channel) cancellation" begin
    for _ in 1:20
        src = CancellationTokenSource()
        ch = Channel{Int}(Inf)
        t = Threads.@spawn begin
            sleep(0.01)
            cancel(src)
        end
        @test_throws OperationCanceledException wait(ch, get_token(src))
        wait(t)
    end
end

@testitem "Concurrent combined source" begin
    for _ in 1:20
        src1 = CancellationTokenSource()
        src2 = CancellationTokenSource()
        combined = CancellationTokenSource(get_token(src1), get_token(src2))
        Threads.@spawn begin
            sleep(0.01)
            cancel(src1)
        end
        wait(get_token(combined))
        @test is_cancellation_requested(combined)
    end
end

@testitem "Multiple threads cancel same source" begin
    for _ in 1:50
        src = CancellationTokenSource()
        tasks = [Threads.@spawn(cancel(src)) for _ in 1:8]
        for t in tasks
            wait(t)
        end
        @test is_cancellation_requested(src)
    end
end

@testitem "Concurrent sleep cancellation" begin
    for _ in 1:10
        src = CancellationTokenSource()
        Threads.@spawn begin
            sleep(0.01)
            cancel(src)
        end
        @test_throws OperationCanceledException sleep(60.0, get_token(src))
    end
end

@testitem "Stress: simultaneous cancel of both parents in combined source" begin
    # Exercises the race where two monitoring tasks inside a combined source
    # fire at the same time.  Before the fix, each task would call
    # schedule() on its sibling, corrupting the workqueue.
    for _ in 1:200
        src1 = CancellationTokenSource()
        src2 = CancellationTokenSource()
        combined = CancellationTokenSource(get_token(src1), get_token(src2))
        # Cancel both parents as close together as possible.
        t1 = Threads.@spawn cancel(src1)
        t2 = Threads.@spawn cancel(src2)
        wait(t1)
        wait(t2)
        wait(get_token(combined))
        @test is_cancellation_requested(combined)
    end
end

@testitem "Stress: cancel token while channel data arrives" begin
    # Exercises the race where the monitoring task is executing
    # lock(c) do notify(cond) end on one thread while the main task
    # finishes and tries to clean up the monitoring task.
    for _ in 1:200
        src = CancellationTokenSource()
        ch = Channel{Int}(1)
        token = get_token(src)

        # Race: put data and cancel at the same time
        t1 = Threads.@spawn put!(ch, 42)
        t2 = Threads.@spawn cancel(src)

        result = try
            take!(ch, token)
        catch e
            e isa OperationCanceledException ? :cancelled : rethrow(e)
        end
        @test result === 42 || result === :cancelled
        wait(t1)
        wait(t2)
    end
end

@testitem "Stress: cancel token while waiting on channel" begin
    for _ in 1:200
        src = CancellationTokenSource()
        ch = Channel{Int}(1)
        token = get_token(src)

        t1 = Threads.@spawn begin
            sleep(0.001)
            put!(ch, 1)
        end
        t2 = Threads.@spawn begin
            sleep(0.001)
            cancel(src)
        end

        result = try
            wait(ch, token)
            :ready
        catch e
            e isa OperationCanceledException ? :cancelled : rethrow(e)
        end
        @test result === :ready || result === :cancelled
        wait(t1)
        wait(t2)
    end
end
