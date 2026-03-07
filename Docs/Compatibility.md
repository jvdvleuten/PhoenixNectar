# Compatibility Notes

This is a breaking rewrite with actor-first APIs.

## Removed old style

- `Socket` / `Channel` / `Push` mutable callback-oriented lifecycle API
- delegate-owner helper patterns
- main-thread-bound API assumptions

## New style

- `PhoenixClient` actor as single mutable runtime owner
- `ChannelHandle` value type
- async operations + AsyncStream-based event consumption

## Sendability

- Core API is actor-isolated.
- Transport bridge still uses a small `@unchecked Sendable` exception for `URLSessionTransport`.
