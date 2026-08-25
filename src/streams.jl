# ---------------------------------------------------------------------------
# Base.eof for libuv streams with cancellation — NON-destructive
#
# The socket overloads in augment_base.jl unblock a pending read by closing
# the stream: for a socket whose protocol state is indeterminate after a
# timeout that is the right call, but it makes the stream unusable. `eof`
# with a token is the opposite primitive: it waits until data is available,
# the stream ends, or the token fires — and on cancellation leaves the
# stream fully usable, so the caller can retry, keep waiting with a new
# token, or consume data that arrives later. This is the building block for
# cancellable read loops (e.g. expect-style pattern waiting on a PTY or
# pipe): wait with `eof(stream, token)`, consume with `bytesavailable` /
# `readavailable`.
#
# The implementation replicates Base.wait_readnb(::LibuvStream, nb) — the
# same iolock/cond/throttle/preserve_handle discipline — with two additions:
# a cancellation check on every wakeup, and a token registration that
# notifies the stream's condition variable on cancel. Base's own readers
# sleep on that same condition and tolerate spurious wakeups (they re-check
# their predicate and sleep again), so waking it is harmless.
#
# Why Julia ≥ 1.6: because the implementation mirrors Base's internal wait
# protocol, it is tied to the protocol's exact shape, and that shape changed
# three times before 1.6 — 1.0/1.1 wait on a plain `x.readnotify` Condition
# with no locking and no `readerror` field; 1.2 introduces the `x.cond`
# lock; 1.3–1.5 add the iolock and `readerror` but not the StatusEOF
# handling. Supporting those eras is possible, but each would need its own
# faithful replica of that era's wait_readnb, tested on that version; the
# stable modern protocol (identical from 1.6 through 1.12) is what is
# supported here.
# ---------------------------------------------------------------------------

@static if VERSION >= v"1.6"

"""
    eof(stream::Base.LibuvStream, token::CancellationToken) -> Bool

Like `eof(stream)` — block until data is available or the stream has
ended — but throw [`OperationCanceledException`](@ref) when `token` is
cancelled.

Unlike the socket `readline`/`read`/`readavailable` overloads in this
package, cancellation is **non-destructive**: the stream is left untouched
and remains fully usable, and output arriving after the cancellation can
still be read. Works for any libuv-backed stream (`Base.PipeEndpoint`,
`Base.TTY`, `Sockets.TCPSocket`, ...).

Combined with `bytesavailable` and `readavailable`, this is the building
block for cancellable read loops:

```julia
src = CancellationTokenSource(5.0)   # 5 s timeout
token = get_token(src)
while !eof(stream, token)            # throws OperationCanceledException on timeout
    process(readavailable(stream))
end
```
"""
function Base.eof(s::Base.LibuvStream, token::CancellationToken)
    is_cancellation_requested(token) && throw(OperationCanceledException(token))
    bytesavailable(s) > 0 && return false
    _wait_readnb_cancellable(s, 1, token)
    # the same determination as Base.eof(::LibuvStream)
    bytesavailable(s) > 0 && return false
    open = isreadable(s)   # must precede the readerror check
    s.readerror === nothing || throw(s.readerror)
    return !open
end

# A cancellable replica of Base.wait_readnb(::LibuvStream, nb): identical
# lock/throttle/preserve discipline, plus a cancellation check on every
# wakeup and a token registration that wakes the stream's condition. The
# registration callback runs synchronously inside cancel(), so the
# lock/notify is pushed to a task to avoid deadlocking the canceller.
function _wait_readnb_cancellable(x::Base.LibuvStream, nb::Int, token::CancellationToken)
    bytesavailable(x.buffer) >= nb && return
    open = isopen(x) && x.status != Base.StatusEOF # must precede readerror check
    x.readerror === nothing || throw(x.readerror)
    open || return
    is_cancellation_requested(token) && throw(OperationCanceledException(token))
    reg = register(token) do
        @_spawn begin
            lock(x.cond)
            try
                notify(x.cond)
            finally
                unlock(x.cond)
            end
        end
    end
    try
        Base.iolock_begin()
        if bytesavailable(x.buffer) >= nb
            Base.iolock_end()
            return
        end
        open = isopen(x) && x.status != Base.StatusEOF
        x.readerror === nothing || throw(x.readerror)
        if !open
            Base.iolock_end()
            return
        end
        oldthrottle = x.throttle
        Base.preserve_handle(x)
        lock(x.cond)
        try
            while bytesavailable(x.buffer) < nb
                x.readerror === nothing || throw(x.readerror)
                isopen(x) || break
                x.status == Base.StatusEOF && break
                is_cancellation_requested(token) &&
                    throw(OperationCanceledException(token))
                x.throttle = max(nb, x.throttle)
                Base.start_reading(x) # ensure we are reading
                Base.iolock_end()
                wait(x.cond)
                unlock(x.cond)
                Base.iolock_begin()
                lock(x.cond)
            end
        finally
            if isempty(x.cond)
                Base.stop_reading(x) # stop reading iff no other read clients
            end
            if oldthrottle <= x.throttle <= nb
                x.throttle = oldthrottle
            end
            Base.unpreserve_handle(x)
            unlock(x.cond)
        end
        Base.iolock_end()
    finally
        close(reg)
    end
    return nothing
end

end # @static if VERSION >= v"1.6"
