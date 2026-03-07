# PhoenixNectar

[![CI](https://github.com/jvdvleuten/PhoenixNectar/actions/workflows/ci.yml/badge.svg)](https://github.com/jvdvleuten/PhoenixNectar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://www.swift.org/)

PhoenixNectar is a Swift 6 Phoenix Channels client for Apple platforms, with modern concurrency-first APIs (`async/await`, `AsyncStream`) and typed event/status helpers.

## Acknowledgement

This project started from the original SwiftPhoenixClient codebase and Phoenix JS channel semantics.  
The goal here is not to replace that work, but to build on it respectfully with a Swift 6-compatible, modernized API surface.

- Swift tools: 6.2
- Swift language mode: 6
- Platforms: iOS 18+, macOS 15+, tvOS 18+, watchOS 11+

## Installation (Swift Package Manager)

Add PhoenixNectar as a package dependency in Xcode or in `Package.swift`:

```swift
.package(url: "https://github.com/jvdvleuten/PhoenixNectar.git", from: "0.1.0")
```

Then add `"PhoenixNectar"` to your target dependencies.

## Quick Start

```swift
import PhoenixNectar

@MainActor
func startClient() throws {
  let socket = try Socket(
    "wss://example.com/socket",
    paramsClosure: { ["token": "user-jwt"] }
  )

  socket.connect()

  let channel = socket.channel("room:lobby")

  Task {
    do {
      let joinReply = try await channel.joinAsync()
      print("joined status:", joinReply.status ?? "unknown")

      let pushReply = try await channel.pushAsync(
        "new_msg",
        payload: ["body": "hello from iOS"]
      )
      print("push status:", pushReply.status ?? "unknown")
    } catch {
      print("channel operation failed:", error)
    }
  }
}
```

## Streaming Messages with `for await`

### Socket-wide stream

```swift
import PhoenixNectar

@MainActor
func observeSocket(_ socket: Socket) {
  Task {
    for await message in socket.messages() {
      print("[socket]", message.topic, message.event, message.payload)
    }
  }
}
```

### Channel event stream

```swift
import PhoenixNectar

@MainActor
func observeChannel(_ channel: Channel) {
  Task {
    for await message in channel.messages(event: "new_msg") {
      if let body = message.payload[string: "body"] {
        print("new_msg:", body)
      }
    }
  }
}
```

## Typed Event and Payload APIs

PhoenixNectar keeps event names and push status values type-safe where it matters:

- `PhoenixEvent.system(.join/.reply/.error/...)` and `PhoenixEvent.custom("...")`
- `PushStatus` (`.ok`, `.error`, `.timeout`)
- `Message.pushStatus` for parsed status values
- `Payload` as `[String: PhoenixValue]` with literal support for common JSON-like values

Example:

```swift
import PhoenixNectar

@MainActor
func typedUsage(_ channel: Channel) async throws {
  let stream = channel.messages(event: .custom("new_msg"))

  Task {
    for await msg in stream {
      print(msg.payload[string: "body"] ?? "")
    }
  }

  let reply = try await channel.pushAsync(
    .custom("new_msg"),
    payload: ["body": "typed event"]
  )

  if reply.pushStatus == .ok {
    print("accepted")
  }
}
```

## Testing

PhoenixNectar is designed for deterministic tests via dependency injection:

- Inject a custom `PhoenixTransport` to simulate open/close/error/message frames.
- Inject a custom `PhoenixScheduler` to control timers (heartbeats, reconnects, push timeouts).
- Use `socket.messages()` / `channel.messages(event:)` and assert emitted `Message` values.

This lets you test reconnect behavior, timeout handling, and channel flows without a live Phoenix server.

## Notes

- Endpoint URLs are normalized to include `/websocket`.
- Query params include `vsn` and values from `params` / `paramsClosure`.

## Project Docs

- Public API: `Docs/PublicAPI.md`
- Compatibility notes: `Docs/Compatibility.md`
- Module boundary notes: `Docs/ModuleBoundary.md`
- Changelog: `CHANGELOG.md`
