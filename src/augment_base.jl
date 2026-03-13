# Helper: get the condition variable that `wait(::Channel)` uses.
# Julia 1.9+ split this into a separate `cond_wait` field;
# older versions use `cond_take` for both wait and take!.
@static if :cond_wait in fieldnames(Channel{Any})
    _channel_wait_cond(c::Channel) = c.cond_wait
else
    _channel_wait_cond(c::Channel) = c.cond_take
end

# ---------------------------------------------------------------------------
# Base.sleep with cancellation
# ---------------------------------------------------------------------------

"""
    sleep(seconds::Real, token::CancellationToken)

Sleep for `seconds`, but wake up early with an
[`OperationCanceledException`](@ref) if `token` is cancelled.

# Examples

```julia
src = CancellationTokenSource()
@async begin sleep(1); cancel(src) end
sleep(60.0, get_token(src))  # throws OperationCanceledException after ~1 s
```
"""
function Base.sleep(sec::Real, token::CancellationToken)
    timer_src = CancellationTokenSource(sec)
    timer_token = get_token(timer_src)
    combined = CancellationTokenSource(timer_token, token)

    try
        wait(get_token(combined))
    finally
        # Ensure the timer is closed even if the external token cancelled us.
        # cancel() is idempotent and closes the internal Timer.
        cancel(timer_src)
    end

    # timer_src was cancelled by cancel() above regardless of who fired first,
    # so check the *original* token to decide the outcome.
    if is_cancellation_requested(token)
        throw(OperationCanceledException(token))
    end
end

# ---------------------------------------------------------------------------
# Base.readline with cancellation  (sockets only)
# ---------------------------------------------------------------------------

"""
    readline(socket::Union{Sockets.PipeEndpoint, Sockets.TCPSocket},
             token::CancellationToken; keep=false)

Read a line from `socket`, but abort with an error if `token` is cancelled
before data arrives.
"""
function Base.readline(s::Union{Sockets.PipeEndpoint,Sockets.TCPSocket}, token::CancellationToken; keep=false)
    done = Threads.Atomic{Bool}(false)

    # Register a callback that enqueues socket notification work.
    # Running lock/notify directly inside cancel() can deadlock because
    # register callbacks are executed synchronously by cancel().
    reg = register(token) do
        if !Threads.atomic_xchg!(done, true)
            @async begin
                # s.cond is a GenericCondition with its own lock; notify requires
                # holding the condition's lock, not the stream's ReentrantLock.
                lock(s.cond) do
                    notify(s.cond, OperationCanceledException(token); error=true)
                end
            end
        end
    end

    try
        return readline(s; keep=keep)
    finally
        # Deregister the callback to prevent notification after completion.
        close(reg)
        # Signal to the callback that it should not notify if it fires anyway.
        Threads.atomic_xchg!(done, true)
    end
end

# ---------------------------------------------------------------------------
# Sockets.accept with cancellation
# ---------------------------------------------------------------------------

"""
    Sockets.accept(server::Union{Sockets.TCPServer, Sockets.PipeServer},
                   token::CancellationToken)
    Sockets.accept(server::Union{Sockets.TCPServer, Sockets.PipeServer},
                   client::Union{Sockets.TCPSocket, Sockets.PipeEndpoint},
                   token::CancellationToken)

Accept a connection from `server`, but abort with an error if `token` is
cancelled before a client arrives.

The listening server remains usable after cancellation.
"""
function _accept_cancellable(f, server, token::CancellationToken)
    is_cancellation_requested(token) && throw(OperationCanceledException(token))

    callback_started = Threads.Atomic{Bool}(false)
    completed = Threads.Atomic{Bool}(false)

    reg = register(token) do
        if completed[]
            return
        end

        if !Threads.atomic_xchg!(callback_started, true)
            @async begin
                lock(server.cond) do
                    if !completed[]
                        notify(server.cond, OperationCanceledException(token); error=true)
                    end
                end
            end
        end
    end

    try
        return f()
    finally
        close(reg)
        Threads.atomic_xchg!(completed, true)
    end
end

function Sockets.accept(server::Sockets.TCPServer, token::CancellationToken)
    return _accept_cancellable(() -> Sockets.accept(server), server, token)
end

function Sockets.accept(server::Sockets.PipeServer, token::CancellationToken)
    return _accept_cancellable(() -> Sockets.accept(server), server, token)
end

function Sockets.accept(server::Sockets.TCPServer, client::Sockets.TCPSocket, token::CancellationToken)
    return _accept_cancellable(() -> Sockets.accept(server, client), server, token)
end

function Sockets.accept(server::Sockets.PipeServer, client::Sockets.PipeEndpoint, token::CancellationToken)
    return _accept_cancellable(() -> Sockets.accept(server, client), server, token)
end

# ---------------------------------------------------------------------------
# Base.wait(::Channel, ::CancellationToken)
# ---------------------------------------------------------------------------

"""
    wait(c::Channel, token::CancellationToken)

Wait for `c` to have data available, but throw
[`OperationCanceledException`](@ref) if `token` is cancelled first.

The channel remains usable after cancellation.

# Examples

```julia
ch = Channel{Int}(1)
src = CancellationTokenSource(5.0)    # 5 s timeout
wait(ch, get_token(src))              # throws after 5 s if no data
```
"""
function Base.wait(c::Channel, token::CancellationToken)
    is_cancellation_requested(token) && throw(OperationCanceledException(token))
    isready(c) && return

    cond = _channel_wait_cond(c)

    done = Threads.Atomic{Bool}(false)

    # Register a callback that enqueues channel notification work.
    # Running lock/notify directly inside cancel() can deadlock because
    # register callbacks are executed synchronously by cancel().
    reg = register(token) do
        if !Threads.atomic_xchg!(done, true)
            @async begin
                lock(c) do
                    notify(cond)
                end
            end
        end
    end

    lock(c)
    try
        while !isready(c)
            Base.check_channel_state(c)
            is_cancellation_requested(token) && throw(OperationCanceledException(token))
            wait(cond)
        end
    finally
        unlock(c)
        # Deregister the callback to prevent notification after completion.
        close(reg)
        # Signal to the callback that it should not notify if it fires anyway.
        Threads.atomic_xchg!(done, true)
    end
    nothing
end

# ---------------------------------------------------------------------------
# Base.take!(::Channel, ::CancellationToken)
# ---------------------------------------------------------------------------

"""
    take!(c::Channel, token::CancellationToken)

Remove and return a value from `c`, but throw
[`OperationCanceledException`](@ref) if `token` is cancelled while waiting
for data.

The channel remains usable after cancellation. Only buffered channels are
supported; unbuffered (size-0) channels will raise an error.

# Examples

```julia
ch = Channel{Int}(10)
src = CancellationTokenSource()
@async begin sleep(1); put!(ch, 42) end
take!(ch, get_token(src))  # returns 42
```
"""
function Base.take!(c::Channel, token::CancellationToken)
    if Base.isbuffered(c)
        _take_buffered_cancellable(c, token)
    else
        _take_unbuffered_cancellable(c, token)
    end
end

function _take_buffered_cancellable(c::Channel, token::CancellationToken)
    lock(c)
    try
        done = Threads.Atomic{Bool}(false)

        # Register a callback that enqueues channel notification work.
        # Running lock/notify directly inside cancel() can deadlock because
        # register callbacks are executed synchronously by cancel().
        reg = register(token) do
            if !Threads.atomic_xchg!(done, true)
                @async begin
                    lock(c) do
                        notify(c.cond_take)
                    end
                end
            end
        end

        try
            while isempty(c.data)
                is_cancellation_requested(token) && throw(OperationCanceledException(token))
                Base.check_channel_state(c)
                wait(c.cond_take)
            end
            is_cancellation_requested(token) && throw(OperationCanceledException(token))
            v = popfirst!(c.data)
            @static if isdefined(Base, :_increment_n_avail)
                Base._increment_n_avail(c, -1)
            end
            notify(c.cond_put, nothing, false, false) # notify only one, since only one slot has become available for a put!.
            return v
        finally
            # Deregister the callback to prevent notification after completion.
            close(reg)
            # Signal to the callback that it should not notify if it fires anyway.
            Threads.atomic_xchg!(done, true)
        end
    finally
        unlock(c)
    end
end

# 0-size channel
function _take_unbuffered_cancellable(c::Channel{T}, token::CancellationToken) where T
    error("Cancellable take! on unbuffered channels is not yet implemented")
end
