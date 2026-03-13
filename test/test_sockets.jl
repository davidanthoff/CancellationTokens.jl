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

@testitem "accept(TCPServer) - cancel before call" begin
    import Sockets

    _port, server = Sockets.listenany(Sockets.localhost, 8000)

    src = CancellationTokenSource()
    token = get_token(src)
    cancel(src)

    @test_throws OperationCanceledException Sockets.accept(server, token)

    close(server)
end

@testitem "accept(TCPServer) - cancel while blocking" begin
    import Sockets

    _port, server = Sockets.listenany(Sockets.localhost, 8000)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    ex = try
        Sockets.accept(server, token)
        nothing
    catch err
        err
    end

    @test ex isa OperationCanceledException
    @test get_token(ex) === token

    close(server)
end

@testitem "accept(TCPServer) - client arrives before cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8000)

    src = CancellationTokenSource()
    token = get_token(src)

    client_task = @async Sockets.connect(Sockets.localhost, port)

    server_conn = Sockets.accept(server, token)
    client_conn = fetch(client_task)

    @test isa(server_conn, Sockets.TCPSocket)
    @test !is_cancellation_requested(src)

    close(server_conn)
    close(client_conn)
    close(server)
end

@testitem "accept(TCPServer) - server reusable after cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8000)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    @test_throws OperationCanceledException Sockets.accept(server, token)

    client_task = @async Sockets.connect(Sockets.localhost, port)

    server_conn = Sockets.accept(server)
    client_conn = fetch(client_task)

    @test isa(server_conn, Sockets.TCPSocket)

    close(server_conn)
    close(client_conn)
    close(server)
end

@testitem "accept(TCPServer, client) - cancel while blocking" begin
    import Sockets

    _port, server = Sockets.listenany(Sockets.localhost, 8000)
    client = Sockets.TCPSocket()

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    ex = try
        Sockets.accept(server, client, token)
        nothing
    catch err
        err
    end

    @test ex isa OperationCanceledException
    @test get_token(ex) === token

    close(client)
    close(server)
end

@testitem "accept(PipeServer) - cancel before call" begin
    import Sockets

    path = Sys.iswindows() ? string(raw"\\.\pipe\CancellationTokens-", time_ns()) : tempname()
    server = Sockets.listen(path)

    src = CancellationTokenSource()
    token = get_token(src)
    cancel(src)

    try
        @test_throws OperationCanceledException Sockets.accept(server, token)
    finally
        close(server)
        if !Sys.iswindows() && ispath(path)
            rm(path; force=true)
        end
    end
end

@testitem "accept(PipeServer) - cancel while blocking" begin
    import Sockets

    path = Sys.iswindows() ? string(raw"\\.\pipe\CancellationTokens-", time_ns()) : tempname()
    server = Sockets.listen(path)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    try
        ex = try
            Sockets.accept(server, token)
            nothing
        catch err
            err
        end

        @test ex isa OperationCanceledException
        @test get_token(ex) === token
    finally
        close(server)
        if !Sys.iswindows() && ispath(path)
            rm(path; force=true)
        end
    end
end

@testitem "accept(PipeServer) - client arrives before cancel" begin
    import Sockets

    path = Sys.iswindows() ? string(raw"\\.\pipe\CancellationTokens-", time_ns()) : tempname()
    server = Sockets.listen(path)

    src = CancellationTokenSource()
    token = get_token(src)

    client_task = @async Sockets.connect(path)

    try
        server_conn = Sockets.accept(server, token)
        client_conn = fetch(client_task)

        @test isa(server_conn, Sockets.PipeEndpoint)
        @test !is_cancellation_requested(src)

        close(server_conn)
        close(client_conn)
    finally
        close(server)
        if !Sys.iswindows() && ispath(path)
            rm(path; force=true)
        end
    end
end

@testitem "accept(PipeServer) - server reusable after cancel" begin
    import Sockets

    path = Sys.iswindows() ? string(raw"\\.\pipe\CancellationTokens-", time_ns()) : tempname()
    server = Sockets.listen(path)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    try
        @test_throws OperationCanceledException Sockets.accept(server, token)

        client_task = @async Sockets.connect(path)

        server_conn = Sockets.accept(server)
        client_conn = fetch(client_task)

        @test isa(server_conn, Sockets.PipeEndpoint)

        close(server_conn)
        close(client_conn)
    finally
        close(server)
        if !Sys.iswindows() && ispath(path)
            rm(path; force=true)
        end
    end
end

@testitem "accept(PipeServer, client) - cancel while blocking" begin
    import Sockets

    path = Sys.iswindows() ? string(raw"\\.\pipe\CancellationTokens-", time_ns()) : tempname()
    server = Sockets.listen(path)
    client = Sockets.PipeEndpoint()

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    try
        ex = try
            Sockets.accept(server, client, token)
            nothing
        catch err
            err
        end

        @test ex isa OperationCanceledException
        @test get_token(ex) === token
    finally
        close(client)
        close(server)
        if !Sys.iswindows() && ispath(path)
            rm(path; force=true)
        end
    end
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
