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
