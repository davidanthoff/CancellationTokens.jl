function Base.sleep(sec::Real, token::CancellationToken)
    # Create a cancel source with a timeout
    timer_src = CancellationTokenSource(sec)

    timer_token = get_token(timer_src)

    # Create a cancel source that cancels either if the timeout source cancels,
    # or when the passed token cancels
    combined = CancellationTokenSource(timer_token, token)

    # Wait for the combined source to cancel
    wait(get_token(combined))

    if is_cancellation_requested(timer_src)
        return
    else
        throw(OperationCanceledException(token))
    end
end

function Base.readline(s::Union{Sockets.PipeEndpoint,Sockets.TCPSocket}, token::CancellationToken; keep=false)
    @async try
        wait(token)

        lock(s.lock) do 
            notify(s.cond, OperationCanceledException(token); error=true)
        end
    catch err
        Base.display_error(err, catch_backtrace())
    end

    return readline(s; keep=keep)
end

function Base.wait(c::Channel, token::CancellationToken)
    is_cancellation_requested(token) && throw(OperationCanceledException(token))
    isready(c) && return
    @static if VERSION >= v"1.3"
        Threads.@spawn begin
            wait(token)
            notify(c.cond_take)
        end
    else
        @async begin
            wait(token)
            notify(c.cond_take)
        end
    end
    lock(c)
    try
        while !isready(c)
            Base.check_channel_state(c)
            is_cancellation_requested(token) && throw(OperationCanceledException(token))
            wait(c.cond_wait)
        end
    finally
        unlock(c)
    end
    nothing
end

Base.take!(c::Channel, token::CancellationToken) = Base.isbuffered(c) ? Base.take_buffered(c, token) : Base.take_unbuffered(c, token)

function Base.take_buffered(c::Channel, token::CancellationToken)
    @info "A"
    lock(c)    
    try
        @info "B"
        t = @static if VERSION >= v"1.3"
            Threads.@spawn try
                @info "1"
                wait(token)
                @info "2"
                lock(c) do
                    notify(c.cond_take)
                end
                @info "3"
            catch err
                Base.display_error(err, catch_backtrace())
                @info "4"
                if !(err isa WaitCanceledException)
                    @info "5"
                    rethrow(err)
                end
            end
        else
            @async try
                wait(token)
                notify(c.cond_take)
            catch err
                if !(err isa WaitCanceledException)
                    rethrow(err)
                end
            end
        end
        try
            @info "C"
            while isempty(c.data)
                @info "D"
                is_cancellation_requested(token) && throw(OperationCanceledException(token))
                @info "E"
                Base.check_channel_state(c)
                @info "F"
                wait(c.cond_take)
                @info "G"
            end
            @info "H"
            is_cancellation_requested(token) && throw(OperationCanceledException(token))
            @info "I"
            v = popfirst!(c.data)
            @info "J"
            _increment_n_avail(c, -1)
            @info "K"
            notify(c.cond_put, nothing, false, false) # notify only one, since only one slot has become available for a put!.
            @info "L"
            return v
        finally
            @info "M"
            schedule(t, WaitCanceledException(), error=true)
        end
    finally
        unlock(c)
    end
end

# 0-size channel
function Base.take_unbuffered(c::Channel{T}, token::CancellationToken) where T
    error("Not yet implemented")
    lock(c)
    try
        Base.check_channel_state(c)
        notify(c.cond_put, nothing, false, false)
        return wait(c.cond_take)::T
    finally
        unlock(c)
    end
end