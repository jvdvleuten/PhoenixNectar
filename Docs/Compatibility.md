# Compatibility Notes

This package intentionally does **not** preserve SwiftPhoenixClient's old callback-owner/delegate helper style.

## Removed legacy style

- `delegateOn(...)` / `delegateReceive(...)`
- `Delegated` helper wrapper
- any `DispatchQueue`/timer queue callback routing model

## Replacement

- Plain closure callbacks for compatibility where needed (`onOpen`, `onClose`, `onError`, `onMessage`)
- Async-first APIs (`messages`, `joinAsync`, `pushAsync`, `leaveAsync`, `responseAsync`)
- Typed payloads via `PhoenixValue`
- Typed event/status APIs via `PhoenixEvent` and `PushStatus`

## Sendability policy

- Goal: avoid `@unchecked Sendable` unless bridging external framework behavior.
- Current exception: `URLSessionTransport` (`URLSessionWebSocketTask` + delegate bridge).
