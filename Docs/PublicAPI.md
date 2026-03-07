# Public API (v0.1 actor rewrite)

## Core Types

- `PhoenixClient` (actor)
- `ChannelHandle` (Sendable value type)
- `PhoenixMessage`
- `PhoenixValue` / `Payload`

## Concurrency APIs

- `try await client.connect()`
- `client.disconnect(...)`
- `await client.channel("topic")`
- `try await channel.join()`
- `try await channel.push(...)`
- `await channel.messages()`
- `client.events()`

## Typed APIs

- `PhoenixEvent` / `PhoenixSystemEvent`
- `PushStatus`
- Generic typed push decode: `channel.push(_:payload:as:)`

## Error Model

- `PhoenixError` with transport/protocol/timeout/decoding cases.
