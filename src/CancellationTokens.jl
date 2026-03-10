"""
    CancellationTokens

A Julia implementation of .NET's cancellation framework for cooperative cancellation
of asynchronous and long-running operations.

The package provides [`CancellationTokenSource`](@ref) objects that produce
[`CancellationToken`](@ref) values. Tokens are passed to cancellable operations
(e.g. `sleep`, `take!`, `wait`) as the last positional argument. When
[`cancel`](@ref) is called on the source, all operations holding a token from
that source are notified and throw an [`OperationCanceledException`](@ref).

Thread-safe on all Julia versions: Julia 1.7+ uses lock-free atomic operations
matching .NET's `Interlocked.CompareExchange` pattern; older versions fall back
to `ReentrantLock`.

# Exports

- [`CancellationTokenSource`](@ref)
- [`CancellationToken`](@ref)
- [`cancel`](@ref)
- [`get_token`](@ref)
- [`is_cancellation_requested`](@ref)
- [`OperationCanceledException`](@ref)
"""
module CancellationTokens

import Sockets

export CancellationTokenSource, CancellationToken, get_token, is_cancellation_requested, cancel, OperationCanceledException

include("event.jl")

@enum CancellationTokenSourceStates NotCanceledState=1 NotifyingState=2 NotifyingCompleteState=3

# ---------------------------------------------------------------------------
# Struct definition — Julia 1.7+ uses @atomic fields for lock-free operations
# matching the .NET CAS + volatile pattern.  Older versions use ReentrantLock.
# ---------------------------------------------------------------------------

@static if VERSION >= v"1.7"
    mutable struct CancellationTokenSource
        @atomic _state::CancellationTokenSourceStates
        _timer::Union{Nothing,Timer}
        @atomic _kernel_event::Union{Nothing,Event}
        _lock::ReentrantLock   # only used for _timer access

        function CancellationTokenSource()
            return new(NotCanceledState, nothing, nothing, ReentrantLock())
        end
    end
else
    mutable struct CancellationTokenSource
        _state::CancellationTokenSourceStates
        _timer::Union{Nothing,Timer}
        _kernel_event::Union{Nothing,Event}
        _lock::ReentrantLock

        function CancellationTokenSource()
            return new(NotCanceledState, nothing, nothing, ReentrantLock())
        end
    end
end

"""
    CancellationTokenSource()
    CancellationTokenSource(seconds::Real)
    CancellationTokenSource(tokens::CancellationToken...)

A source of cancellation signals. Create one, hand out tokens with
[`get_token`](@ref), and call [`cancel`](@ref) when the operation should stop.

# Constructors

- `CancellationTokenSource()` — a manually-cancelled source.
- `CancellationTokenSource(seconds)` — auto-cancels after `seconds`.
- `CancellationTokenSource(token1, token2, ...)` — cancels when **any**
  parent token is cancelled (linked / combined source).

# Examples

```julia
src = CancellationTokenSource()
token = get_token(src)

@async begin
    sleep(1.0)
    cancel(src)
end

wait(token)  # blocks until cancel is called
```

```julia
# Auto-cancel after 5 seconds
src = CancellationTokenSource(5.0)
```

```julia
# Cancel when either parent fires
combined = CancellationTokenSource(get_token(src1), get_token(src2))
```
"""
CancellationTokenSource

# ---------------------------------------------------------------------------
# Timer constructor (shared — _timer is not atomic in either version)
# ---------------------------------------------------------------------------

function CancellationTokenSource(timespan_in_seconds::Real)
    x = CancellationTokenSource()

    x._timer = Timer(timespan_in_seconds) do _
        cancel(x)
    end

    return x
end

# ---------------------------------------------------------------------------
# Core operations — version-split
# ---------------------------------------------------------------------------

@static if VERSION >= v"1.7"

    # Lock-free state transition via CAS, matching .NET's
    # Interlocked.CompareExchange on _state.
    function _internal_notify(x::CancellationTokenSource)
        # Exactly one thread can win this CAS.
        (_, success) = @atomicreplace x._state NotCanceledState => NotifyingState
        success || return

        # Timer cleanup still needs the lock (_timer is not atomic).
        lock(x._lock) do
            if x._timer !== nothing
                close(x._timer)
                x._timer = nothing
            end
        end

        # Signal the event if a waiter has installed one.
        event = @atomic :acquire x._kernel_event
        if event !== nothing
            notify(event)
        end

        @atomic :release x._state = NotifyingCompleteState
    end

    # Single atomic read — equivalent to .NET's volatile read of _state.
    is_cancellation_requested(x::CancellationTokenSource) = (@atomic :acquire x._state) > NotCanceledState

else # VERSION < v"1.7"

    function _internal_notify(x::CancellationTokenSource)
        lock(x._lock) do
            if x._state == NotCanceledState
                x._state = NotifyingState

                if x._timer !== nothing
                    close(x._timer)
                    x._timer = nothing
                end

                # Notify the event but keep it alive — its `set` flag ensures
                # any future wait() calls return immediately.
                if x._kernel_event !== nothing
                    notify(x._kernel_event)
                end

                x._state = NotifyingCompleteState
            end
        end
    end

    is_cancellation_requested(x::CancellationTokenSource) = x._state > NotCanceledState

end

# ---------------------------------------------------------------------------
# Shared public API
# ---------------------------------------------------------------------------

"""
    cancel(src::CancellationTokenSource)

Signal cancellation. All tasks waiting on tokens from `src` will be unblocked.
Calling `cancel` more than once is a no-op (idempotent). Thread-safe.

See also [`is_cancellation_requested`](@ref), [`get_token`](@ref).
"""
function cancel(x::CancellationTokenSource)
    _internal_notify(x)
    return
end

# CancellationToken

"""
    CancellationToken

A lightweight, immutable handle obtained from a [`CancellationTokenSource`](@ref)
via [`get_token`](@ref).  Pass it to cancellable operations as the last
positional argument.

Tokens are cheap to copy and safe to share across tasks and threads.

See also [`is_cancellation_requested`](@ref), [`wait`](@ref).
"""
struct CancellationToken
    _source::CancellationTokenSource
end

"""
    get_token(src::CancellationTokenSource) -> CancellationToken

Return a [`CancellationToken`](@ref) linked to `src`.  Multiple calls return
independent token objects that all reflect the same cancellation state.
"""
get_token(x::CancellationTokenSource) = CancellationToken(x)

"""
    is_cancellation_requested(src::CancellationTokenSource) -> Bool
    is_cancellation_requested(token::CancellationToken) -> Bool

Return `true` if [`cancel`](@ref) has been called (or a timeout has expired).
This is a non-blocking, lock-free check on Julia 1.7+.

# Examples

```julia
src = CancellationTokenSource()
is_cancellation_requested(src)        # false
cancel(src)
is_cancellation_requested(src)        # true
is_cancellation_requested(get_token(src))  # true
```
"""
is_cancellation_requested(x::CancellationToken) = is_cancellation_requested(x._source)

# ---------------------------------------------------------------------------
# wait(::CancellationToken) — version-split
# ---------------------------------------------------------------------------

@static if VERSION >= v"1.7"

    # Lock-free wait matching .NET's WaitHandle pattern:
    #  1. Atomic read of _kernel_event
    #  2. If nothing, CAS a new Event into place (loser uses winner's event)
    #  3. Double-check _state after installing — if cancel() already ran and
    #     missed our event, we signal it ourselves (idempotent).
    function Base.wait(x::CancellationToken)
        # Fast path (lock-free atomic read)
        is_cancellation_requested(x) && return

        # Get or create event via CAS
        event = @atomic :acquire x._source._kernel_event
        if event === nothing
            new_event = Event()
            (old, success) = @atomicreplace x._source._kernel_event nothing => new_event
            event = success ? new_event : old
        end

        # Double-check: if cancel() already ran, it may have read
        # _kernel_event as nothing and skipped notify().
        # The seq_cst CAS on _kernel_event and the seq_cst CAS on _state
        # guarantee that at least one side observes the other's write.
        # notify() is idempotent, so double-signaling is harmless.
        if is_cancellation_requested(x)
            notify(event)
            return
        end

        wait(event)
    end

else # VERSION < v"1.7"

    function Base.wait(x::CancellationToken)
        # Fast path (no lock needed)
        is_cancellation_requested(x) && return

        # Atomically check state + get/create event under the lock.
        # This prevents the TOCTOU race where cancel() fires between our
        # check above and the wait() below.
        event = lock(x._source._lock) do
            is_cancellation_requested(x) && return nothing
            if x._source._kernel_event === nothing
                x._source._kernel_event = Event()
            end
            return x._source._kernel_event
        end

        event === nothing && return
        wait(event)
    end

end

@doc """
    wait(token::CancellationToken)

Block the current task until the token's source is cancelled.  Returns
immediately if already cancelled.

This is used internally by the cancellable overloads of `sleep`, `take!`,
etc., but can also be called directly to build custom cancellable operations.
""" Base.wait(::CancellationToken)

# ---------------------------------------------------------------------------
# Exception types (shared)
# ---------------------------------------------------------------------------

"""
    OperationCanceledException <: Exception

Thrown when a cancellable operation is interrupted because its
[`CancellationToken`](@ref) was cancelled.

Retrieve the token that triggered the exception with [`get_token`](@ref).

# Examples

```julia
try
    sleep(60.0, token)
catch ex::OperationCanceledException
    @info "Cancelled" token=get_token(ex)
end
```
"""
struct OperationCanceledException <: Exception
    _token::CancellationToken
end

struct WaitCanceledException <: Exception
end

"""
    get_token(ex::OperationCanceledException) -> CancellationToken

Return the [`CancellationToken`](@ref) that caused the exception.
"""
get_token(x::OperationCanceledException) = x._token

# ---------------------------------------------------------------------------
# Combined source (shared — only uses public API + _internal_notify)
# ---------------------------------------------------------------------------

function CancellationTokenSource(tokens::CancellationToken...)
    x = CancellationTokenSource()

    # Fast-path: if any parent token is already cancelled, skip spawning
    # monitoring tasks entirely.  This avoids a race where a spawned task
    # completes instantly and calls `schedule()` on a sibling task that
    # has not started running yet, corrupting Julia's workqueue.
    if any(is_cancellation_requested, tokens)
        _internal_notify(x)
        return x
    end

    tasks = Vector{Task}(undef, length(tokens))

    for (i,token) in enumerate(tokens)
        tasks[i] = @static if VERSION >= v"1.3"
            Threads.@spawn try
                wait(token)
                _internal_notify(x)

                for (j,task) in enumerate(tasks)
                    if j != i
                        try
                            schedule(task, WaitCanceledException(), error=true)
                        catch
                            # Task may have already completed
                        end
                    end
                end
            catch err
                if !(err isa WaitCanceledException)
                    rethrow(err)
                end
            end
        else
            @async try
                wait(token)
                _internal_notify(x)

                for (j,task) in enumerate(tasks)
                    if j != i
                        try
                            schedule(task, WaitCanceledException(), error=true)
                        catch
                            # Task may have already completed
                        end
                    end
                end
            catch err
                if !(err isa WaitCanceledException)
                    rethrow(err)
                end
            end
        end
    end

    return x
end

"""
    close(src::CancellationTokenSource)

Equivalent to [`cancel(src)`](@ref cancel). Provided so that
`CancellationTokenSource` can be used with `do`-block resource patterns.
"""
function Base.close(x::CancellationTokenSource)
    cancel(x)
end

include("augment_base.jl")

end # module
