# Public API (Swift 6)

## Core Types

- `Socket`
- `Channel`
- `Push`
- `Message`
- `PhoenixValue` / `Payload`

## Concurrency-first APIs

- `Socket.messages(...) -> AsyncStream<Message>`
- `Channel.messages(event:...) -> AsyncStream<Message>`
- `Channel.joinAsync(...)`
- `Channel.pushAsync(...)`
- `Channel.leaveAsync(...)`
- `Push.responseAsync()`

## Typed APIs

- `PhoenixEvent` (`.system(...)` and `.custom(String)`)
- `PhoenixSystemEvent`
- `PushStatus`
- `Message.pushStatus`

## Timing / Scheduling

- `PhoenixScheduler` protocol for injection
- `ClockScheduler` default implementation using `ContinuousClock` + `Task.sleep`

## Logging

- `PhoenixLogger`
- `LogEvent`
- `LogLevel`
