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

    threw = Ref(false)
    try
        readline(client, token)
    catch ex
        threw[] = true
    end
    @test threw[]

    close(client)
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
    @test !is_cancellation_requested(src)

    close(client)
    close(server)
end
