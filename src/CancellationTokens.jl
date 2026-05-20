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

export CancellationTokenSource, CancellationToken, CancellationTokenRegistration, get_token, is_cancellation_requested, cancel, register, OperationCanceledException

@enum CancellationTokenSourceStates NotCanceledState=1 NotifyingState=2 NotifyingCompleteState=3

mutable struct CancellationTokenSource
    @atomic _state::CancellationTokenSourceStates
    _timer::Union{Nothing,Timer}
    @atomic _cond::Union{Nothing,Threads.Condition}
    @atomic _callbacks::Union{Nothing,Vector{Pair{Int,Any}}}  # id => callback, protected by _lock
    _next_callback_id::Int
    _lock::ReentrantLock

    function CancellationTokenSource()
        return new(NotCanceledState, nothing, nothing, nothing, 1, ReentrantLock())
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
# Timer constructor
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

        # Timer cleanup and callback snapshot under the lock.
        callbacks = lock(x._lock) do
            if x._timer !== nothing
                close(x._timer)
                x._timer = nothing
            end

            cbs = x._callbacks
            @atomic x._callbacks = nothing

            return cbs
        end

        # Signal the condition if a waiter has installed one.
        cond = @atomic x._cond
        if cond !== nothing
            lock(cond) do
                notify(cond)
            end
        end

        # Invoke registered callbacks synchronously (like .NET).
        if callbacks !== nothing
            for (_, cb) in callbacks
                try
                    cb()
                catch
                end
            end
        end

        @atomic x._state = NotifyingCompleteState
    end

    # Single atomic read — equivalent to .NET's volatile read of _state.
    _is_cancellation_requested(x::CancellationTokenSource) = (@atomic x._state) > NotCanceledState

else # VERSION < v"1.7"

    function _internal_notify(x::CancellationTokenSource)
        callbacks = lock(x._lock) do
            if x._state == NotCanceledState
                x._state = NotifyingState

                if x._timer !== nothing
                    close(x._timer)
                    x._timer = nothing
                end

                cbs = x._callbacks
                x._callbacks = nothing

                # Notify the condition but keep it alive — its `set` flag ensures
                # any future wait() calls return immediately.
                if x._cond !== nothing
                    notify(x._cond)
                end

                x._state = NotifyingCompleteState
                return cbs
            end
            return nothing
        end

        # Invoke registered callbacks synchronously (like .NET).
        if callbacks !== nothing
            for (_, cb) in callbacks
                try
                    cb()
                catch
                end
            end
        end
    end

    _is_cancellation_requested(x::CancellationTokenSource) = x._state > NotCanceledState

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
    is_cancellation_requested(token::CancellationToken) -> Bool

Return `true` if [`cancel`](@ref) has been called (or a timeout has expired).
This is a non-blocking, lock-free check on Julia 1.7+.

# Examples

```julia
src = CancellationTokenSource()
token = get_token(src)
is_cancellation_requested(token)  # false
cancel(src)
is_cancellation_requested(token)  # true
```
"""
is_cancellation_requested(x::CancellationToken) = _is_cancellation_requested(x._source)

# ---------------------------------------------------------------------------
# wait(::CancellationToken) — version-split
# ---------------------------------------------------------------------------

@static if VERSION >= v"1.7"

    function _get_or_create_condition(src::CancellationTokenSource)
        # Fast path: check if condition already exists.
        cond = @atomic src._cond
        if cond !== nothing
            return cond
        end

        # Slow path: create a new condition and install it via CAS.
        new_cond = Threads.Condition(src._lock)
        (old, success) = @atomicreplace src._cond nothing => new_cond
        return success ? new_cond : old
    end

    function _get_or_create_callbacks(src::CancellationTokenSource)
        # Fast path: check if condition already exists.
        callbacks = @atomic src._callbacks
        if callbacks !== nothing
            return callbacks
        end

        # Slow path: create a new condition and install it via CAS.
        new_callbacks = Vector{Pair{Int,Any}}()
        (old, success) = @atomicreplace src._callbacks nothing => new_callbacks
        return success ? new_callbacks : old
    end

else # VERSION < v"1.7"

    function _get_or_create_condition(src::CancellationTokenSource)
        lock(src._lock) do
            if src._cond === nothing
                src._cond = Threads.Condition(src._lock)
            end
            return src._cond
        end
    end

    function _get_or_create_callbacks(src::CancellationTokenSource)
        lock(src._lock) do
            if src._callbacks === nothing
                src._callbacks = Vector{Pair{Int,Any}}()
            end
            return src._callbacks
        end
    end
end

function Base.wait(x::CancellationToken)
    # Fast path (no lock needed)
    is_cancellation_requested(x) && return

    cond = _get_or_create_condition(x._source)

    lock(cond)
    try
        while !is_cancellation_requested(x)
                wait(cond)
        end
    finally
        unlock(cond)
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

"""
    get_token(ex::OperationCanceledException) -> CancellationToken

Return the [`CancellationToken`](@ref) that caused the exception.
"""
get_token(x::OperationCanceledException) = x._token

# ---------------------------------------------------------------------------
# CancellationTokenRegistration — handle for deregistering a callback
# ---------------------------------------------------------------------------

"""
    CancellationTokenRegistration

A handle returned by [`register`](@ref) that can be used to deregister the
callback via `close(registration)`.  Closing is idempotent and thread-safe.
"""
struct CancellationTokenRegistration
    _source::CancellationTokenSource
    _id::Int
end

"""
    close(registration::CancellationTokenRegistration)

Deregister a previously registered callback.  After this call the callback
will not be invoked, even if the source is later cancelled.  No-op if the
callback was already deregistered or if the source has already been cancelled.
"""
function Base.close(r::CancellationTokenRegistration)
    lock(r._source._lock) do
        if r._id == 0 || r._source._callbacks === nothing
            return
        end
        idx = findfirst(p -> p.first == r._id, r._source._callbacks)
        if idx !== nothing
            deleteat!(r._source._callbacks, idx)
        end
    end
    nothing
end

# ---------------------------------------------------------------------------
# register — synchronous callback registration (matching .NET)
# ---------------------------------------------------------------------------

"""
    register(callback, token::CancellationToken) -> CancellationTokenRegistration

Register `callback` (a zero-argument callable) to be invoked synchronously
when `cancel` is called on the token's source.  If the token is already
cancelled, `callback` is invoked immediately before returning.

Returns a [`CancellationTokenRegistration`](@ref) that can be `close`d to
deregister the callback.

Callbacks are invoked synchronously during `cancel()`, so they should be
non-blocking and fast — similar to .NET's
`CancellationToken.Register(Action)`.

# Examples

```julia
src = CancellationTokenSource()
reg = register(get_token(src)) do
    @info "Cancelled!"
end
cancel(src)  # prints "Cancelled!"
```

```julia
# Deregister before cancel — callback is NOT invoked
src = CancellationTokenSource()
reg = register(get_token(src)) do
    error("should not run")
end
close(reg)
cancel(src)  # nothing happens
```
"""
function register(callback, token::CancellationToken)
    _register(callback, token._source)
end


function _register(callback, src::CancellationTokenSource)
    # Fast path: already cancelled — invoke immediately.
    if _is_cancellation_requested(src)
        callback()
        return CancellationTokenRegistration(src, 0)
    end

    callbacks = _get_or_create_callbacks(src)

    id = lock(src._lock) do
        # Double-check under lock: cancel() may have won the race.
        if _is_cancellation_requested(src)
            return nothing
        end
        cb_id = src._next_callback_id
        src._next_callback_id = cb_id + 1
        push!(callbacks, cb_id => callback)
        return cb_id
    end

    if id === nothing
        # Source was cancelled between the fast-path check and acquiring
        # the lock — invoke immediately.
        callback()
        return CancellationTokenRegistration(src, 0)
    end

    return CancellationTokenRegistration(src, id)
end

# ---------------------------------------------------------------------------
# Combined source (shared — uses register instead of spawning tasks)
# ---------------------------------------------------------------------------

function CancellationTokenSource(tokens::CancellationToken...)
    x = CancellationTokenSource()

    # Fast-path: if any parent token is already cancelled, skip registration.
    if any(is_cancellation_requested, tokens)
        _internal_notify(x)
        return x
    end

    # Register a callback on each parent token.  When any parent fires,
    # _internal_notify(x) is called synchronously — no tasks are spawned.
    # _internal_notify is idempotent (CAS-guarded), so multiple callbacks
    # calling it concurrently is safe.
    for token in tokens
        register(token) do
            _internal_notify(x)
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

# ---------------------------------------------------------------------------
# Internal helper: prefer Threads.@spawn (Julia ≥ 1.3) over @async.
# Threads.@spawn schedules work on the thread pool, avoiding task-pinning
# pitfalls of @async.  On Julia < 1.3, fall back to @async.
# ---------------------------------------------------------------------------
@static if VERSION >= v"1.3"
    macro _spawn(expr)
        :(Threads.@spawn $(esc(expr)))
    end
else
    macro _spawn(expr)
        :(@async $(esc(expr)))
    end
end

include("augment_base.jl")

# ---------------------------------------------------------------------------
# Precompile directives — all methods are type-stable, so precompile()
# cascades to all inferrable callees automatically.
# ---------------------------------------------------------------------------

function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

    # Constructors
    precompile(Tuple{Type{CancellationTokenSource}})
    precompile(Tuple{Type{CancellationTokenSource}, Float64})
    precompile(Tuple{Type{CancellationTokenSource}, CancellationToken, CancellationToken})
    precompile(Tuple{Type{OperationCanceledException}, CancellationToken})

    # Core API
    precompile(cancel, (CancellationTokenSource,))
    precompile(get_token, (CancellationTokenSource,))
    precompile(get_token, (OperationCanceledException,))
    precompile(is_cancellation_requested, (CancellationToken,))
    precompile(Tuple{typeof(register), Any, CancellationToken})

    # Base extensions — CancellationTokens core
    precompile(wait, (CancellationToken,))
    precompile(close, (CancellationTokenSource,))
    precompile(close, (CancellationTokenRegistration,))

    # Base extensions — augment_base
    precompile(sleep, (Float64, CancellationToken))
    precompile(wait, (Channel{Any}, CancellationToken))
    precompile(take!, (Channel{Any}, CancellationToken))
    precompile(readline, (Sockets.TCPSocket, CancellationToken))
    precompile(readline, (Sockets.PipeEndpoint, CancellationToken))
    precompile(read, (Sockets.TCPSocket, Int, CancellationToken))
    precompile(read, (Sockets.PipeEndpoint, Int, CancellationToken))

    # Internal hot paths
    precompile(_internal_notify, (CancellationTokenSource,))
    precompile(_is_cancellation_requested, (CancellationTokenSource,))
    precompile(Tuple{typeof(_register), Any, CancellationTokenSource})
end

_precompile_()

end # module
