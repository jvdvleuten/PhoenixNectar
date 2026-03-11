# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning.

## [Unreleased]

### Added
- `reconnectOnCleanClose` option on `ConnectionPolicy` — reconnects on server-initiated close code 1000 by default; set to `false` to treat clean close as final.
- `channel.subscribeBinary(to:)` stream for receiving binary broadcasts on a channel.
- `ping(policy:)` for measuring round-trip latency to the server.
- `connectionStateStream()` for observing socket lifecycle transitions.
- Typed topic model (`Topic`) and typed connection lifecycle model (`ConnectionState`).
- `connectParamsProvider` and `authTokenProvider` closures re-evaluated on each connect/reconnect.
- `joinChannel(_:params:)` convenience APIs including `Encodable` params overload.
- `PhoenixReply` envelope for protocol-level typed replies (`status` + `response`).
- Typed channel subscriptions via `channel.subscribe(to: Event<T>)`.
- `ClientMetricEvent` observability hook (`setMetricsHook`) and `OSLog.Logger` integration (`setLogger`).
- Outbound buffer with configurable limit, overflow policy, and metrics for dropped frames.
- E2E test suite covering public rooms, private rooms, binary uploads, connection lifecycle, ping, leave/rejoin, multi-channel, and auth error paths.
- CI now includes Phoenix-backed E2E job on macOS.

### Changed
- `connectParamsProvider` errors now propagate through `connect()` instead of being silently swallowed.
- `StreamForwarder` data race fixed — replaced `@unchecked Sendable` with `OSAllocatedUnfairLock`.
- Transport event registration race fixed — uses synchronous `AsyncStream.makeStream()` instead of `Task`-based async registration.
- Defensive cleanup in transport `connect()` to prevent `URLSession` leaks on reconnect.
- Optimized buffer removal from `removeAll(where:)` to `firstIndex(of:)` + `remove(at:)`.
- Deduplicated `TopicStreamHub` and `BinaryTopicStreamHub` into generic `TopicStreamHub<T: Sendable>`.
- Test infrastructure rewritten to be event-driven (stream-based synchronization) instead of poll-based, eliminating `Task.sleep` patterns from unit tests.

## [0.1.0] - 2026-03-07

### Added
- Swift 6 package (`swift-tools-version: 6.1`) for iOS 16+, macOS 15+, tvOS 18+, watchOS 11+.
- Concurrency-first APIs with `AsyncStream` and async channel/push operations.
- Typed payload model via `PhoenixValue` and typed event/status helpers.
- Structured logging protocol (`PhoenixLogger`).
- Injectable scheduling abstraction (`PhoenixScheduler`) for deterministic tests.
- Swift Testing-based unit test suite and CI workflow (Linux + macOS).

### Changed
- Ported/modernized from SwiftPhoenixClient semantics to Swift 6-native patterns.
- Transport uses async WebSocket send/receive where Foundation supports it.

[Unreleased]: https://github.com/jvdvleuten/PhoenixNectar/compare/0.1.0...HEAD
[0.1.0]: https://github.com/jvdvleuten/PhoenixNectar/releases/tag/0.1.0
