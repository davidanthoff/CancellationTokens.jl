# Changelog

All notable changes to CancellationTokens.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `register(callback, token)` to register a callback that is invoked synchronously when `cancel` is called, matching .NET's `CancellationToken.Register(Action)`. If the token is already cancelled, the callback is invoked immediately.
- `CancellationTokenRegistration` struct returned by `register`, with `close(registration)` for deregistration (matching .NET's `CancellationTokenRegistration.Dispose()`).
- `CancellationToken` is now an explicit export (previously usable but not exported).
- `Base.take!(::Channel, ::CancellationToken)` for cancellable channel take operations (buffered channels only).
- `Base.wait(::Channel, ::CancellationToken)` for cancellable channel wait operations.
- `Base.readline(::Union{Sockets.PipeEndpoint, Sockets.TCPSocket}, ::CancellationToken)` for cancellable socket reads.
- `Base.close(::CancellationTokenSource)` as an alias for `cancel`, enabling `do`-block resource patterns.
- `WaitCanceledException` internal exception for clean task teardown in combined sources and cancellable operations.
- Thread safety via lock-free atomic (`@atomic`) operations on Julia 1.7+, matching .NET's `Interlocked.CompareExchange` pattern. Older Julia versions fall back to `ReentrantLock`.
- Lock-free `wait(::CancellationToken)` using CAS on Julia 1.7+ with double-check to prevent missed notifications.
- Documentation site via Documenter.jl with API reference, base method overloads, and usage guide.
- Thread-safety tests (`test_threads.jl`).
- Expanded test suite for base method overloads, channels, sockets, core functionality, and callback registration.
- `Sockets` stdlib dependency for cancellable `readline`.

### Changed

- Combined `CancellationTokenSource(tokens...)` now uses synchronous callbacks (`register`) instead of spawning monitoring tasks (`Threads.@spawn`/`@async`). Cancellation propagation is now immediate and deterministic, and eliminates `InterruptException` errors from orphaned monitoring tasks.
- `CancellationTokenSource` struct now includes `_callbacks` and `_next_callback_id` fields for callback registration (internal; no public API change beyond the new `register` function).
- `_internal_notify` now invokes registered callbacks synchronously during cancellation, after notifying the event. Each callback is wrapped in `try/catch` so one failure does not prevent others from running.
- `CancellationTokenSource` struct now includes a `_lock::ReentrantLock` field (internal; no public API change).
- `_internal_notify` is now thread-safe, using CAS on Julia 1.7+ and lock-based state transitions on older versions.
- `_waithandle` / event creation uses CAS on Julia 1.7+ so multiple threads cannot create duplicate events.
- `Base.sleep(::Real, ::CancellationToken)` now uses `try/finally` to ensure the internal timer is always closed, and calls `cancel` for cleanup rather than checking `is_cancellation_requested` on the timer source.
- Timer constructor now calls `cancel(x)` (public API) instead of `_internal_notify(x)` directly.
- CI updated to use `TestItemRunner` workflow.

### Fixed

- `InterruptException` in monitoring tasks spawned by `CancellationTokenSource(tokens...)`. These tasks had no error handling and could throw when interrupted during cleanup. Fixed by replacing task-based monitoring with synchronous callback registration.
- Race condition in `wait(::CancellationToken)` where `cancel()` could fire between the `is_cancellation_requested` check and the `wait(event)` call, causing a hang. Fixed via double-check after event installation on Julia 1.7+ and lock-based atomic check on older versions.

## [1.0.0] - 2021-07-11

### Added

- `CancellationTokenSource` for creating cancellation signal sources.
- `CancellationToken` lightweight immutable handle.
- `cancel(::CancellationTokenSource)` to signal cancellation.
- `get_token(::CancellationTokenSource)` to obtain tokens from a source.
- `get_token(::OperationCanceledException)` to retrieve the token from an exception.
- `is_cancellation_requested(::CancellationTokenSource)` and `is_cancellation_requested(::CancellationToken)` for non-blocking cancellation checks.
- `wait(::CancellationToken)` to block until cancellation.
- `OperationCanceledException` for signaling cancelled operations.
- `CancellationTokenSource(seconds::Real)` constructor for auto-cancellation after a timeout.
- `CancellationTokenSource(tokens::CancellationToken...)` constructor for combined/linked sources.
- `Base.sleep(::Real, ::CancellationToken)` for cancellable sleep.
- `Event` polyfill for Julia < 1.1.
- Support for Julia 1.0+.

[Unreleased]: https://github.com/davidanthoff/CancellationTokens.jl/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/davidanthoff/CancellationTokens.jl/releases/tag/v1.0.0
