# Getting Started

Create a client, connect once, then join a topic, subscribe, and push.

```swift
import PhoenixNectar

struct SendMessage: Encodable, Sendable {
  let body: String
}

struct SendReply: Decodable, Sendable {
  let messageID: String
}

struct MessagePosted: Decodable, Sendable {
  let id: String
  let body: String
}

let client = try Socket(
  endpoint: "wss://api.example.com/socket"
)

try await client.connect()

let channel = try await client.joinChannel("room:engineering")
let postedMessages = Event<MessagePosted>("message:posted")
let postMessage = Push<SendMessage, SendReply>("message:send")

Task {
  for try await event in await channel.subscribe(to: postedMessages) {
    print(event.id, event.body)
  }
}

let reply = try await channel.push(postMessage, payload: SendMessage(body: "hello"))
print(reply.messageID)
```

## See Also

- ``Socket``
- ``Channel``
- ``Topic``
