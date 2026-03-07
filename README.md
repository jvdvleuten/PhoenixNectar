# PhoenixNectar

[![CI](https://github.com/jvdvleuten/PhoenixNectar/actions/workflows/ci.yml/badge.svg)](https://github.com/jvdvleuten/PhoenixNectar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://www.swift.org/)

PhoenixNectar is a Swift 6 Phoenix Channels client rebuilt around actor isolation and modern async APIs.

## Acknowledgement

This project started from the original SwiftPhoenixClient and Phoenix JS channel semantics.
This rewrite keeps that foundation in mind while moving to a cleaner Swift 6 actor-first design.

## Requirements

- Swift tools: 6.2
- Swift language mode: 6
- Platforms: iOS 18+, macOS 15+, tvOS 18+, watchOS 11+

## Install (SPM)

```swift
.package(url: "https://github.com/jvdvleuten/PhoenixNectar.git", from: "0.1.0")
```

## Clean Actor API

```swift
import PhoenixNectar

let client = try PhoenixClient(endpoint: "wss://example.com/socket", paramsClosure: {
  ["token": "jwt"]
})

try await client.connect()

let channel = await client.channel("room:lobby")
_ = try await channel.join()

let reply = try await channel.push(.custom("new_msg"), payload: ["body": "hello"])
print(reply.responsePayload)
```

## for-await Streams

```swift
let channel = await client.channel("room:lobby")
let stream = await channel.messages()

Task {
  for await message in stream {
    print(message.topic, message.event, message.payload)
  }
}
```

## Typed Push Decode

```swift
struct CreateInput: Codable, Sendable { let body: String }
struct CreateReply: Codable, Sendable { let id: Int }

let value: CreateReply = try await channel.push(
  .custom("create"),
  payload: CreateInput(body: "hello"),
  as: CreateReply.self
)
```

## Design Notes

- Actor-first client runtime (`PhoenixClient`).
- AsyncSequence-first message/event flow.
- Typed payload model (`PhoenixValue`).
- Typed event/status model (`PhoenixEvent`, `PushStatus`).
- Foundation transport bridge uses async WebSocket send/receive APIs.

## Project Docs

- Public API: `Docs/PublicAPI.md`
- Compatibility notes: `Docs/Compatibility.md`
- Module boundary notes: `Docs/ModuleBoundary.md`
- Changelog: `CHANGELOG.md`
