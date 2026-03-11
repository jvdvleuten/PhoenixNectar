# API Reference

Compact reference for the public PhoenixNectar API.

---

## On This Page

- [Start Here](#start-here)
- [Core Types](#core-types)
- [Socket](#socket)
- [Channel](#channel)
- [Policies](#policies)
- [Observability](#observability)
- [Advanced Surface](#advanced-surface)

---

## Start Here

For most apps, you only need:

1. `Socket`
2. `connect()`
3. `joinChannel(...)`
4. `subscribe(to: Event<T>)`
5. `push(Push<Req, Resp>, payload: ...)`
6. `connectionStateStream()`

```swift
import PhoenixNectar

struct ChatMessage: Codable, Sendable {
  let body: String
}

let socket = try Socket(endpoint: "wss://api.example.com/socket")
try await socket.connect()

let channel = try await socket.joinChannel("room:lobby")

Task {
  let posted = Event<ChatMessage>("message:posted")
  for try await message in await channel.subscribe(to: posted) {
    print("received:", message.body)
  }
}

let send = Push<ChatMessage, ChatMessage>("message:send")
let reply = try await channel.push(send, payload: .init(body: "hello"))
print("echo:", reply.body)
```

Use `joinChannel(..., params: ...)` only when the server expects a `phx_join` payload.

---

## Core Types

| Type | Purpose |
| --- | --- |
| `Socket` | Owns the transport, reconnect logic, and joined channel intent |
| `Channel` | Handle for one topic — push, subscribe, join, leave |
| `Topic` | Lightweight topic wrapper; plain strings work for most apps |
| `Push<Request, Response>` | Typed outbound event descriptor |
| `Event<EventPayload>` | Typed inbound event descriptor |
| `PhoenixReply` | Raw Phoenix reply envelope (`status` + `response`) |
| `PhoenixMessage` | Raw inbound text message |
| `RequestPolicy` | Timeout and retry policy for a single operation |
| `ConnectionPolicy` | Heartbeat, reconnect, and clean-close behavior |
| `ConnectionState` | Socket lifecycle state (`.connecting`, `.connected`, `.disconnected`) |
| `PhoenixError` | Transport, timeout, protocol, and decode failures |

---

## Socket

### Create

```swift
init(
  endpoint: String,
  configuration: Socket.Configuration = .default,
  authTokenProvider: AuthTokenProvider? = nil
) throws
```

Use this when you do not need dynamic connect params.

```swift
init<ConnectParams: Encodable & Sendable>(
  endpoint: String,
  configuration: Socket.Configuration = .default,
  connectParamsProvider: @escaping @Sendable () -> ConnectParams?,
  authTokenProvider: AuthTokenProvider? = nil
) throws
```

Use this when your socket connect request needs query params or metadata.

### Lifecycle

```swift
connect() async throws
disconnect(code: Int = 1000, reason: String? = nil) async
ping(policy: RequestPolicy = .default) async throws -> Duration
```

### Join a Channel

```swift
joinChannel(_ topic: String, policy: RequestPolicy = .default) async throws -> Channel
joinChannel<T: Encodable>(_ topic: String, params: T, policy: RequestPolicy = .default) async throws -> Channel
```

`params` becomes the payload of `phx_join`. Most channels do not need it.

```swift
struct RoomJoin: Encodable, Sendable {
  let role: String
}

let channel = try await socket.joinChannel(
  "room:engineering",
  params: RoomJoin(role: "member")
)
```

### Observe Connection State

```swift
connectionStateStream(
  bufferingPolicy: AsyncStream<ConnectionState>.Continuation.BufferingPolicy = .bufferingNewest(1)
) async -> AsyncStream<ConnectionState>
```

```swift
Task {
  for await state in await socket.connectionStateStream() {
    print("state:", state)
  }
}
```

---

## Channel

### Main Surface

```swift
topic: Topic
join(policy: RequestPolicy = .default) async throws -> PhoenixReply
leave(policy: RequestPolicy = .default) async throws -> PhoenixReply
```

### Subscribe

```swift
subscribe(
  to event: Event<EventPayload>,
  bufferingPolicy: AsyncStream<PhoenixMessage>.Continuation.BufferingPolicy = .unbounded
) async -> AsyncThrowingStream<EventPayload, Error>
```

```swift
struct MessagePosted: Decodable, Sendable {
  let body: String
}

let posted = Event<MessagePosted>("message:posted")

for try await event in await channel.subscribe(to: posted) {
  print(event.body)
}
```

### Push a Typed Event

```swift
push<Request: Encodable & Sendable, Response: Decodable & Sendable>(
  _ event: Push<Request, Response>,
  payload: Request,
  policy: RequestPolicy = .default
) async throws -> Response
```

```swift
struct SendMessage: Encodable, Sendable {
  let body: String
}

struct SendReply: Decodable, Sendable {
  let accepted: Bool
}

let send = Push<SendMessage, SendReply>("message:send")
let reply = try await channel.push(send, payload: .init(body: "hello"))
print(reply.accepted)
```

### Raw Push and Binary Push

```swift
push<T: Encodable>(
  _ eventName: String,
  payload: T,
  policy: RequestPolicy = .default
) async throws -> PhoenixReply

pushBinary(
  _ eventName: String,
  data: Data,
  policy: RequestPolicy = .default
) async throws -> PhoenixReply
```

Use these when you do not want a typed `Push<Req, Resp>` descriptor.

### Decode a Raw Reply

`PhoenixReply` is the raw reply type for direct Phoenix semantics or manual decode control.

```swift
let reply = try await channel.push("message:send", payload: ["body": "hello"])

guard reply.status == .ok else {
  throw PhoenixError.serverError(reply)
}

struct Ack: Decodable, Sendable {
  let accepted: Bool
}

let ack = try reply.decode(Ack.self)
print(ack.accepted)
```

---

## Policies

### RequestPolicy

```swift
RequestPolicy(
  timeout: Duration = .seconds(10),
  retries: Int = 0,
  retryBackoff: @escaping @Sendable (Int) -> Duration = { _ in .zero }
)
```

Controls timeout and retry behavior for a single join, push, or ping.

### ConnectionPolicy

```swift
ConnectionPolicy(
  heartbeatInterval: Duration = .seconds(30),
  reconnectBackoff: @escaping @Sendable (Int) -> Duration = { ... },
  reconnectOnCleanClose: Bool = true
)
```

| Parameter | Default | Description |
| --- | --- | --- |
| `heartbeatInterval` | 30s | How often the client sends heartbeat pings |
| `reconnectBackoff` | Exponential (50ms → 5s) | Delay function given the attempt number |
| `reconnectOnCleanClose` | `true` | Whether to reconnect on server-initiated close code 1000 |

Set `reconnectOnCleanClose: false` if your app treats a clean server close as final:

```swift
let socket = try Socket(
  endpoint: "wss://api.example.com/socket",
  configuration: .init(
    connectionPolicy: ConnectionPolicy(reconnectOnCleanClose: false)
  )
)
```

---

## Observability

```swift
setLogger(_ logger: Logger?)
setMetricsHook(_ metricsHook: ClientMetricsHook?)
```

Use these for integration with app logging or metrics pipelines.

---

## Advanced Surface

These are public but not the first APIs most apps should reach for:

| API | When to use |
| --- | --- |
| `Topic` | When you need a first-class topic value instead of a plain string |
| `PhoenixReply` | When you need raw reply status and payload inspection |
| `PhoenixMessage` | When you need raw inbound message access |
| `setLogger(_:)` | When you need structured logging via `OSLog.Logger` |
| `setMetricsHook(_:)` | When you need metrics pipeline integration |
| `pushBinary(...)` | When you need binary channel payloads |
| `subscribeBinary(to:)` | When you need to receive binary broadcasts on a channel |

If you are starting fresh, begin with the [Start Here](#start-here) section and add these only when your app needs them.
