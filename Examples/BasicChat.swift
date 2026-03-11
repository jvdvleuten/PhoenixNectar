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

func runBasicChat(tokenStore: TokenStore) async throws {
  let client = try Socket(
    endpoint: "wss://api.example.com/socket",
    configuration: .default,
    authTokenProvider: {
      tokenStore.current()
    }
  )

  try await client.connect()

  let channel = try await client.joinChannel("room:engineering")
  let postedMessages = Event<MessagePosted>("message:posted")
  let postMessage = Push<SendMessage, SendReply>("message:send")

  Task {
    for try await message in await channel.subscribe(to: postedMessages) {
      print("received:", message.id, message.body)
    }
  }

  let reply = try await channel.push(postMessage, payload: SendMessage(body: "hello"))
  print("sent:", reply.messageID)
}

protocol TokenStore {
  func current() -> String?
}
