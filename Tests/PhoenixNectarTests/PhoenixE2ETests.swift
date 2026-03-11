import Foundation
import Testing
@testable import PhoenixNectar

@Suite(.timeLimit(.minutes(3)))
struct PhoenixE2ETests {
  @Test
  func privateRoomChatFlowWithProvidersMatchesDocumentation() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    struct SendMessage: Codable, Sendable {
      let body: String
    }

    struct SendReply: Codable, Sendable {
      let message_id: String
      let accepted: Bool
    }

    struct MessagePosted: Codable, Sendable {
      let id: String
      let from_user_id: String
      let body: String
      let sent_at: String
    }

    let userA = "user-a-\(UUID().uuidString.lowercased())"
    let userB = "user-b-\(UUID().uuidString.lowercased())"
    let roomID = "engineering"

    let clientA = try Socket(
      endpoint: endpoint,
      connectParamsProvider: {
        ["device_id": .string("device-docs-a")]
      },
      authTokenProvider: {
        "user:\(userA)"
      }
    )

    let clientB = try Socket(
      endpoint: endpoint,
      connectParamsProvider: {
        ["device_id": .string("device-docs-b")]
      },
      authTokenProvider: {
        "user:\(userB)"
      }
    )

    try await clientA.connect()
    try await clientB.connect()

    let topic = Topic("private:room:\(roomID)")
    let channelA = try await clientA.joinChannel(topic, policy: RequestPolicy(timeout: .seconds(3)))
    let channelB = try await clientB.joinChannel(topic, policy: RequestPolicy(timeout: .seconds(3)))

    let postedMessages = Event<MessagePosted>("message:posted")
    let postMessage = Push<SendMessage, SendReply>("message:send")

    let streamB = await channelB.subscribe(to: postedMessages)
    let sendReply = try await channelA.push(postMessage, payload: SendMessage(body: "hello from docs"), policy: RequestPolicy(timeout: .seconds(3)))
    #expect(sendReply.accepted == true)
    #expect(!sendReply.message_id.isEmpty)

    let received = try await withThrowingTaskGroup(of: MessagePosted?.self) { group in
      group.addTask {
        var iterator = streamB.makeAsyncIterator()
        return try await iterator.next()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw PhoenixError.timeout
      }
      let value = try await group.next()!
      group.cancelAll()
      return value
    }

    #expect(received?.id == sendReply.message_id)
    #expect(received?.from_user_id == userA)
    #expect(received?.body == "hello from docs")

    await clientA.disconnect()
    await clientB.disconnect()
  }

  @Test
  func invalidAuthTokenCannotJoinPrivateRoom() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    let topic = Topic("private:room:engineering")

    let client = try Socket(
      endpoint: endpoint,
      connectParamsProvider: {
        ["device_id": .string("device-a")]
      },
      authTokenProvider: {
        "invalid"
      }
    )

    try await client.connect()

    await #expect(throws: PhoenixError.self) {
      _ = try await client.joinChannel(topic, policy: RequestPolicy(timeout: Duration.seconds(1)))
    }

    await client.disconnect()
  }

  @Test
  func missingAuthTokenCannotJoinPrivateRoom() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    let topic = Topic("private:room:engineering")

    let client = try Socket(endpoint: endpoint, connectParamsProvider: {
      ["device_id": .string("device-no-auth")]
    })

    try await client.connect()
    await #expect(throws: Error.self) {
      _ = try await client.joinChannel(topic, policy: RequestPolicy(timeout: .seconds(1)))
    }

    await client.disconnect()
  }

  @Test
  func binaryUploadOnPrivateRoomIsSupported() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    let uploaderID = "user-a-\(UUID().uuidString.lowercased())"
    let receiverID = "user-b-\(UUID().uuidString.lowercased())"
    let topic = Topic("private:room:engineering")

    let uploader = try Socket(
      endpoint: endpoint,
      connectParamsProvider: {
        ["device_id": .string("device-binary")]
      },
      authTokenProvider: {
        "user:\(uploaderID)"
      }
    )

    let receiver = try Socket(
      endpoint: endpoint,
      connectParamsProvider: {
        ["device_id": .string("device-binary-receiver")]
      },
      authTokenProvider: {
        "user:\(receiverID)"
      }
    )

    try await uploader.connect()
    try await receiver.connect()
    let uploaderChannel = try await uploader.joinChannel(topic, policy: RequestPolicy(timeout: .seconds(3)))
    _ = try await receiver.joinChannel(topic, policy: RequestPolicy(timeout: .seconds(3)))
    let binaryStream = await receiver.binaryMessages(topic: topic)

    let bytes = Data([0, 1, 2, 3, 255])
    let reply = try await uploaderChannel.pushBinary(
      "binary:upload",
      data: bytes,
      policy: RequestPolicy(timeout: .seconds(3))
    )
    #expect(reply.status == .ok)
    #expect(reply.response[bool: "accepted"] == true)
    #expect(reply.response[int: "size"] == bytes.count)

    let received = try await withThrowingTaskGroup(of: PhoenixBinaryMessage?.self) { group in
      group.addTask {
        var iterator = binaryStream.makeAsyncIterator()
        while let next = await iterator.next() {
          if next.event == .named("image:posted") {
            return next
          }
        }
        return nil
      }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw PhoenixError.timeout
      }
      let value = try await group.next()!
      group.cancelAll()
      return value
    }

    #expect(received?.topic == topic)
    #expect(received?.event == .named("image:posted"))
    #expect(received?.payload == bytes)

    await uploader.disconnect()
    await receiver.disconnect()
  }

  // MARK: - Public Room Channel

  @Test
  func publicRoomNewMsgBroadcastsToAllSubscribers() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    struct EchoReply: Codable, Sendable {
      let accepted: Bool
      let echo: String
    }

    struct NewMsg: Codable, Sendable {
      let body: String
    }

    let sender = try Socket(endpoint: endpoint, authTokenProvider: { "user:lobby-sender" })
    let listener = try Socket(endpoint: endpoint, authTokenProvider: { "user:lobby-listener" })
    try await sender.connect()
    try await listener.connect()

    let senderChannel = try await sender.joinChannel("room:lobby", policy: RequestPolicy(timeout: .seconds(3)))
    let listenerChannel = try await listener.joinChannel("room:lobby", policy: RequestPolicy(timeout: .seconds(3)))

    let newMsg = Push<NewMsg, EchoReply>("new_msg")
    let inbound = Event<NewMsg>("new_msg")
    let stream = await listenerChannel.subscribe(to: inbound)

    let reply = try await senderChannel.push(newMsg, payload: NewMsg(body: "lobby hello"), policy: RequestPolicy(timeout: .seconds(3)))
    #expect(reply.accepted == true)
    #expect(reply.echo == "lobby hello")

    let received = try await raceTimeout(seconds: 3) {
      var iterator = stream.makeAsyncIterator()
      return try await iterator.next()
    }
    #expect(received?.body == "lobby hello")

    await sender.disconnect()
    await listener.disconnect()
  }

  @Test
  func publicRoomCatchAllEventEchoesPayload() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    let client = try Socket(endpoint: endpoint, authTokenProvider: { "user:catchall" })
    try await client.connect()
    let channel = try await client.joinChannel("room:lobby", policy: RequestPolicy(timeout: .seconds(3)))

    // RoomChannel has a catch-all that replies {:ok, payload} and broadcasts.
    let reply = try await channel.push("custom:event", payload: CustomPayload(value: 42), policy: RequestPolicy(timeout: .seconds(3)))
    #expect(reply.status == .ok)
    let decoded = try reply.decode(CustomPayload.self)
    #expect(decoded.value == 42)

    await client.disconnect()
  }

  // MARK: - Connection Lifecycle

  @Test
  func connectionStateStreamEmitsExpectedTransitions() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    let client = try Socket(endpoint: endpoint, authTokenProvider: { "user:statetest" })

    // Register stream BEFORE connect so we capture all transitions.
    let stateStream = await client.connectionStateStream()

    actor StateCollector {
      var states: [ConnectionState] = []
      func append(_ state: ConnectionState) { states.append(state) }
      func all() -> [ConnectionState] { states }
    }

    let collector = StateCollector()
    let collectTask = Task {
      for await state in stateStream {
        await collector.append(state)
        if case .disconnected = state { break }
      }
    }

    // Small delay to ensure the collector is consuming the stream.
    try await Task.sleep(for: .milliseconds(50))

    try await client.connect()

    // Wait for connection to stabilize.
    try await Task.sleep(for: .milliseconds(500))

    await client.disconnect()
    _ = await collectTask.value

    let states = await collector.all()

    // Should see at least: connecting → connected → disconnected
    #expect(states.contains { $0 == .connecting })
    #expect(states.contains { $0 == .connected })
    #expect(states.contains {
      if case .disconnected = $0 { return true }
      return false
    })
  }

  @Test
  func pingReturnsPositiveDuration() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    let client = try Socket(endpoint: endpoint, authTokenProvider: { "user:pingtest" })
    try await client.connect()

    // Wait for connected state before pinging.
    let stateStream = await client.connectionStateStream()
    for await state in stateStream {
      if state == .connected { break }
    }

    let latency = try await client.ping(policy: RequestPolicy(timeout: .seconds(3)))
    #expect(latency > .zero)
    #expect(latency < .seconds(3))

    await client.disconnect()
  }

  // MARK: - Channel Leave & Rejoin

  @Test
  func leaveAndRejoinChannelWorks() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    struct NewMsg: Codable, Sendable {
      let body: String
    }

    let client = try Socket(endpoint: endpoint, authTokenProvider: { "user:rejointest" })
    try await client.connect()

    let channel = try await client.joinChannel("room:lobby", policy: RequestPolicy(timeout: .seconds(3)))
    let leaveReply = try await channel.leave(policy: RequestPolicy(timeout: .seconds(3)))
    #expect(leaveReply.status == .ok)

    // Rejoin the same channel.
    let rejoinReply = try await channel.join(policy: RequestPolicy(timeout: .seconds(3)))
    #expect(rejoinReply.status == .ok)

    // Verify channel is functional after rejoin — RoomChannel replies with {accepted, echo}.
    struct EchoReply: Codable, Sendable { let accepted: Bool; let echo: String }
    let reply = try await channel.push(
      Push<NewMsg, EchoReply>("new_msg"),
      payload: NewMsg(body: "after rejoin"),
      policy: RequestPolicy(timeout: .seconds(3))
    )
    #expect(reply.echo == "after rejoin")

    await client.disconnect()
  }

  // MARK: - Multiple Channels

  @Test
  func multipleChannelsOnSameSocket() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    struct NewMsg: Codable, Sendable {
      let body: String
    }

    struct EchoReply: Codable, Sendable {
      let accepted: Bool
      let echo: String
    }

    let userID = "user-multi-\(UUID().uuidString.lowercased())"
    let client = try Socket(
      endpoint: endpoint,
      connectParamsProvider: { ["device_id": .string("device-multi")] },
      authTokenProvider: { "user:\(userID)" }
    )
    try await client.connect()

    // Join both a public and private channel on the same socket.
    let lobby = try await client.joinChannel("room:lobby", policy: RequestPolicy(timeout: .seconds(3)))
    let privateRoom = try await client.joinChannel("private:room:multi-test", policy: RequestPolicy(timeout: .seconds(3)))

    // Push to both channels and verify independent operation.
    let lobbyReply = try await lobby.push(
      Push<NewMsg, EchoReply>("new_msg"),
      payload: NewMsg(body: "lobby msg"),
      policy: RequestPolicy(timeout: .seconds(3))
    )

    struct SendMessage: Codable, Sendable { let body: String }
    struct SendReply: Codable, Sendable { let message_id: String; let accepted: Bool }
    let privateReply = try await privateRoom.push(
      Push<SendMessage, SendReply>("message:send"),
      payload: SendMessage(body: "private msg"),
      policy: RequestPolicy(timeout: .seconds(3))
    )

    #expect(lobbyReply.echo == "lobby msg")
    #expect(privateReply.accepted == true)
    #expect(!privateReply.message_id.isEmpty)

    await client.disconnect()
  }

  // MARK: - Invalid Topic

  @Test
  func joiningPrivateRoomWithEmptyIDFails() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["PHOENIX_E2E_URL"], !endpoint.isEmpty else {
      return
    }

    let client = try Socket(
      endpoint: endpoint,
      authTokenProvider: { "user:test" }
    )
    try await client.connect()

    // "private:room:" with empty room_id should return an error.
    await #expect(throws: PhoenixError.self) {
      _ = try await client.joinChannel("private:room:", policy: RequestPolicy(timeout: .seconds(2)))
    }

    await client.disconnect()
  }

  // MARK: - Helpers

  private func raceTimeout<T: Sendable>(
    seconds: Int,
    operation: @escaping @Sendable () async throws -> T?
  ) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw PhoenixError.timeout
      }
      let value = try await group.next()!
      group.cancelAll()
      return value
    }
  }
}

private struct CustomPayload: Codable, Sendable {
  let value: Int
}
