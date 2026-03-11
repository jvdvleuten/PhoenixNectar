import Foundation
import PhoenixNectar

struct SendMessage: Encodable, Sendable {
  let body: String
}

struct SendReply: Decodable, Sendable {
  let accepted: Bool
  let messageID: String
}

struct MessagePosted: Decodable, Sendable {
  let id: String
  let fromUserID: String
  let body: String
}

struct ConnectParams: Encodable, Sendable {
  let deviceID: String
}

func makeAuthenticatedChatClient(
  endpoint: String,
  deviceID: @escaping @Sendable () -> String,
  authToken: @escaping @Sendable () -> String?
) throws -> Socket {
  try Socket(
    endpoint: endpoint,
    connectParamsProvider: {
      ConnectParams(deviceID: deviceID())
    },
    authTokenProvider: authToken
  )
}

func runAuthenticatedChatFlow(client: Socket) async throws {
  try await client.connect()

  let channel = try await client.joinChannel("private:room:engineering")
  let postedMessages = Event<MessagePosted>("message:posted")
  let postMessage = Push<SendMessage, SendReply>("message:send")

  Task {
    for try await message in await channel.subscribe(to: postedMessages) {
      print("message:", message.fromUserID, message.body)
    }
  }

  let reply = try await channel.push(postMessage, payload: SendMessage(body: "hello"))
  print("accepted:", reply.accepted, "id:", reply.messageID)
}
