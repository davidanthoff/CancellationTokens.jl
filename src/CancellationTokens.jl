module CancellationTokens

import Dates

export CancellationTokenSource, token, is_cancellation_requested, cancel, OperationCanceledException

include("event.jl")

@enum CancellationTokenSourceStates NotCanceledState=1 NotifyingState=2 NotifyingCompleteState=3

mutable struct CancellationTokenSource
    _state::CancellationTokenSourceStates
    _timer::Union{Nothing,Timer}
    _kernel_event::Union{Nothing,Event} # TODO Event is Julia > 1.1, make it work on 1.0

    function new()
        return new(NotCanceledState, nothing, nothing)
    end
end

function CancellationTokenSource(timespan_in_milliseconds::Int)
    x = CancellationTokenSource()

    t = Timer(timespan_in_milliseconds)

    @async begin
        wait(t)
        _internal_notify(x)
    end

    x._timer = t

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
            close(x._kernel_event)
            x._kernel_event = nothing
        end

        x._state = NotifyingCompleteState
    end
end

function cancel(x::CancellationTokenSource)
    _internal_notify(x)

    return
end

is_cancellation_requested(x::CancellationTokenSource) = x._state > NotCanceledState

function _waithandle(x::CancellationTokenSource)
    if x._kernel_event===nothing
        x._kernel_event = Base.Event()
    end

    return x._kernel_event
end

# CancellationToken

struct CancellationToken
    _source::CancellationTokenSource
end

token(x::CancellationTokenSource) = CancellationToken(x)

is_cancellation_requested(x::CancellationToken) = is_cancellation_requested(x._source)

_waithandle(x::CancellationToken) = _waithandle(x._source)

Base.wait(x::CancellationToken) = wait(_waithandle(x))

# OperationCanceledException

struct OperationCanceledException <: Exception
    _token::CancellationToken
end

token(x::OperationCanceledException) = x._token

function CancellationTokenSource(tokens::AbstractVector{<:CancellationToken}...)
    x = CancellationTokenSource()

    for token in tokens
        @async begin
            wait(token)
            _internal_notify(x)
        end
    end

    return x
end

end # module
