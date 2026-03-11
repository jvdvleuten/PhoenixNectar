import PhoenixNectar

struct SendMessage: Encodable, Sendable {
  let body: String
}

struct SendReply: Decodable, Sendable {
  let accepted: Bool
}

struct MessagePosted: Decodable, Sendable {
  let body: String
}

enum ChatRoom {
  static func topic(id: String) -> String { "chat:\(id)" }
  static let postMessage = Push<SendMessage, SendReply>("message:send")
  static let posted = Event<MessagePosted>("message:posted")
}

func useTypedCatalog(client: Socket) async throws {
  let channel = try await client.joinChannel(ChatRoom.topic(id: "engineering"))

  let _ = try await channel.push(ChatRoom.postMessage, payload: SendMessage(body: "hi"))

  for try await event in await channel.subscribe(to: ChatRoom.posted) {
    print(event.body)
  }
}
