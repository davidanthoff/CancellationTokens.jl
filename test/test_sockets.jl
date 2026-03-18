@testitem "readline(TCPSocket) - cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8000)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        conn = Sockets.accept(server)
        # Don't send anything — let readline block
        sleep(5.0)
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    @test_throws OperationCanceledException readline(client, token)
    # Socket should be closed after cancellation
    @test !isopen(client)

    close(server)
end

@testitem "readline(TCPSocket) - data arrives before cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8000)

    src = CancellationTokenSource()

    @async begin
        conn = Sockets.accept(server)
        sleep(0.1)
        println(conn, "hello")
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)
    line = readline(client, get_token(src))
    @test line == "hello"
    @test !is_cancellation_requested(get_token(src))

    close(client)
    close(server)
end

@testitem "readline(TCPSocket) - cancel does not crash other readers" begin
    import Sockets

    # Regression test for issue #24:
    # Cancelling one reader must not inject errors into other tasks
    # waiting on the same socket. The cancellation closes the socket,
    # so other readers get a clean I/O error — not OperationCanceledException.
    port, server = Sockets.listenany(Sockets.localhost, 8000)

    @async begin
        conn = Sockets.accept(server)
        # Don't send anything — let both readers block
        sleep(5.0)
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)

    src = CancellationTokenSource()

    # Task 1: readline with cancellation token (will be cancelled)
    task1 = @async begin
        try
            readline(client, get_token(src))
        catch ex
            ex
        end
    end

    # Task 2: plain readline on the same socket (no cancellation token)
    task2 = @async begin
        try
            readline(client)
            :ok
        catch ex
            ex
        end
    end

    # Give both tasks time to start blocking
    sleep(0.2)

    # Cancel the token — this closes the socket
    cancel(src)

    # Wait for both tasks to finish
    result1 = fetch(task1)
    result2 = fetch(task2)

    # Task 1 should get OperationCanceledException
    @test result1 isa OperationCanceledException

    # Task 2 should NOT get OperationCanceledException —
    # it should get a regular I/O error from the socket closing
    @test !(result2 isa OperationCanceledException)

    close(server)
end
