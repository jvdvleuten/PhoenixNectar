<p align="center">
  <img src="Brand/phoenix-nectar-logo.svg" alt="Phoenix Nectar" width="640" />
</p>

<h3 align="center">Phoenix Channels client for Swift 6</h3>

<p align="center">
  <a href="https://github.com/jvdvleuten/PhoenixNectar/actions/workflows/ci.yml"><img src="https://github.com/jvdvleuten/PhoenixNectar/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT" /></a>
  <a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-6.1%2B-orange.svg" alt="Swift 6.1+" /></a>
</p>

<p align="center">
  Actor-owned runtime &bull; typed push &amp; event helpers &bull; reconnect/rejoin &bull; async streams
</p>

---

> If you want a client that stays close to the Phoenix JavaScript API, use
> [SwiftPhoenixClient](https://github.com/davidstump/SwiftPhoenixClient).
> PhoenixNectar is for Swift 6 codebases that want a smaller, concurrency-first API.

## Requirements

| Platform  | Minimum |
| --------- | ------- |
| Swift     | 6.1+    |
| iOS       | 16+     |
| macOS     | 15+     |
| tvOS      | 18+     |
| watchOS   | 11+     |

## Install

```swift
.package(url: "https://github.com/jvdvleuten/PhoenixNectar.git", from: "0.1.0")
```

## Quickstart

```swift
import PhoenixNectar

struct ChatMessage: Codable, Sendable {
  let body: String
}

let client = try Socket(endpoint: "wss://api.example.com/socket")

try await client.connect()

let channel = try await client.joinChannel("room:lobby")

// Subscribe to inbound events
let posted = Event<ChatMessage>("message:posted")
Task {
  for try await message in await channel.subscribe(to: posted) {
    print(message.body)
  }
}

// Push a typed event and await the reply
let send = Push<ChatMessage, ChatMessage>("message:send")
let reply = try await channel.push(send, payload: ChatMessage(body: "hello"))
print(reply.body)
```

For most apps, this is enough:

1. `connect()`
2. `joinChannel("room:lobby")`
3. `subscribe(to: Event<T>)`
4. `push(Push<Req, Resp>, payload: ...)`

Use `joinChannel(..., params: ...)` only when your server expects a `phx_join` payload. Use `authTokenProvider` and `connectParamsProvider` only when your socket connect flow needs them.

---

## Contents

- [Why This Library](#why-this-library)
- [Core Behavior](#core-behavior)
- [Authentication and Join Params](#authentication-and-join-params)
- [Connection State](#connection-state)
- [Raw Replies and Binary Pushes](#raw-replies-and-binary-pushes)
- [Demo](#demo)
- [Docs](#docs)

## Why This Library

- **`async`/`await`** instead of callback-heavy channel APIs
- **Typed `Push` and `Event`** helpers for compile-time safety
- **Actor-owned runtime** state with Swift 6 strict concurrency
- **Reconnect, heartbeat, and automatic rejoin** built in
- **Compact public API** with lower-level APIs still available when needed

## Core Behavior

| Behavior | Detail |
| --- | --- |
| Provider closures | Re-evaluated on connect and reconnect |
| Transport loss | Triggers reconnect with configured backoff |
| Rejoin | Joined topics are automatically rejoined after reconnect |
| Heartbeat timeout | Follows the same reconnect path |
| Clean close (1000) | Reconnects by default; disable with `reconnectOnCleanClose: false` |
| Explicit `disconnect()` | Treated as intentional — no auto-reconnect |
| State observation | `connectionStateStream()` emits lifecycle transitions |

## Authentication and Join Params

| Parameter | Purpose |
| --- | --- |
| `authTokenProvider` | Phoenix auth tokens — re-evaluated on each connect/reconnect |
| `connectParamsProvider` | Socket-level metadata (device ID, locale, etc.) |
| `joinChannel(..., params:)` | Channel-specific `phx_join` payloads only |

## Connection State

```swift
for await state in await client.connectionStateStream() {
  print(state) // .connecting, .connected, .disconnected(reason)
}
```

## Raw Replies and Binary Pushes

Use typed `Push`/`Event` first. Drop to raw replies only when needed:

```swift
let reply = try await channel.push("message:send", payload: ["body": "hello"])
guard reply.status == .ok else {
  throw PhoenixError.serverError(reply)
}
```

Binary channel payloads:

```swift
let reply = try await channel.pushBinary("binary:upload", data: bytes)
```

## Demo

Start the local Phoenix backend:

```bash
./scripts/run-demo-backend.sh
```

Then:

- Open `http://127.0.0.1:4000/chat_demo.html` for the browser demo
- Open `demos/ChatShowcaseApp/ChatShowcaseApp.xcodeproj` for the iOS demo

Default demo endpoint: `ws://127.0.0.1:4000/socket`

## Docs

| Document | Description |
| --- | --- |
| [API Reference](./Docs/API-Reference.md) | Full public API with signatures and examples |
| [Examples](./Examples/README.md) | Short reference snippets for common tasks |
| [E2E Harness](./e2e/README.md) | Phoenix backend for integration testing |
| [Contributing](./CONTRIBUTING.md) | Development setup and PR guidelines |
| [Changelog](./CHANGELOG.md) | Version history |
