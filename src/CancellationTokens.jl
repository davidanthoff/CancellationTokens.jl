module CancellationTokens

export
    CancellationTokenSource,
    get_token,
    is_cancellation_requested,
    cancel,
    OperationCanceledException,
    register,
    register_closable

include("event.jl")

@enum CancellationTokenSourceStates NotCanceledState=1 NotifyingState=2 NotifyingCompleteState=3

mutable struct CancellationTokenSource
    _state::CancellationTokenSourceStates
    _timer::Union{Nothing,Timer}
    _kernel_event::Union{Nothing,Event}
    _registrations::Union{Nothing,Vector{Any}}

    function CancellationTokenSource()
        return new(NotCanceledState, nothing, nothing, nothing)
    end
end

function CancellationTokenSource(timespan_in_seconds::Real)
    x = CancellationTokenSource()

    x._timer = Timer(timespan_in_seconds) do _
        _internal_notify(x)
    end

    return x
end

function _internal_notify(x::CancellationTokenSource)
    if x._state==NotCanceledState
        x._state = NotifyingState

        if x._timer!==nothing
            close(x._timer)
            x._timer = nothing
        end

        if x._kernel_event!==nothing
            notify(x._kernel_event)
            x._kernel_event = nothing
        end

        x._state = NotifyingCompleteState

        _execute_callbacks(x)
    end
end

function _execute_callbacks(cts::CancellationTokenSource, throw_on_first_exception::Bool)
    exceptions = []

    for callback in cts._registrations
        try
            callback()
        catch err
            if throw_on_first_exception
                rethrow(err)
            else
                push!(exceptions, err)
            end
        end
    end

    if length(exceptions) > 0
        throw(CompositeException(exceptions))
    end

    return nothing
end

function cancel(x::CancellationTokenSource)
    _internal_notify(x)

    return
end

is_cancellation_requested(x::CancellationTokenSource) = x._state > NotCanceledState

function _waithandle(x::CancellationTokenSource)
    if x._kernel_event===nothing
        x._kernel_event = Event()
    end

    return x._kernel_event
end

function register(cts::CancellationTokenSource, f)
    if !is_cancellation_requested(cts)
        if cts._registrations===nothing
            cts._registrations = []
        end

        push!(cts._registrations, f)
    else
        f()
        return nothing
    end
end

function register_closable(cts::CancellationTokenSource, x)
    register(cts, ()->close(x))
end

# CancellationToken

struct CancellationToken
    _source::CancellationTokenSource
end

get_token(x::CancellationTokenSource) = CancellationToken(x)

is_cancellation_requested(x::CancellationToken) = is_cancellation_requested(x._source)

_waithandle(x::CancellationToken) = _waithandle(x._source)

function Base.wait(x::CancellationToken)
    if is_cancellation_requested(x)
        return
    else
        wait(_waithandle(x))
    end
end

register(ct::CancellationToken, f) = register(ct._source, f)

register_closable(ct:CancellationToken, x) = register_closable(ct._source, x)

# OperationCanceledException

struct OperationCanceledException <: Exception
    _token::CancellationToken
end

get_token(x::OperationCanceledException) = x._token

function CancellationTokenSource(tokens::CancellationToken...)
    x = CancellationTokenSource()

    for t in tokens
        @async begin
            wait(t)
            _internal_notify(x)
        end
    end

    return x
end

include("augment_base.jl")

end # module
