import Testing
@testable import PhoenixNectar

struct ClientActorTests {
  @Test
  func joinAndPushRoundTrip() async throws {
    let transport = TestTransport()
    let client = try PhoenixClient(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })

    try await client.connect()
    transport.simulateOpen()

    let channel = await client.channel("room:lobby")

    let joinTask = Task { try await channel.join() }
    try await Task.sleep(for: .milliseconds(10))
    let joinFrame = try #require(transport.lastSentFrame())

    transport.simulateMessage(
      joinRef: joinFrame.ref,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await joinTask.value

    let pushTask = Task { try await channel.push(.custom("new_msg"), payload: ["body": "hi"]) }
    try await Task.sleep(for: .milliseconds(10))
    let pushFrame = try #require(transport.lastSentFrame())

    transport.simulateMessage(
      joinRef: joinFrame.ref,
      ref: pushFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": ["accepted": true]]
    )

    let reply = try await pushTask.value
    #expect(reply.responsePayload[bool: "accepted"] == true)
  }

  @Test
  func channelMessageStreamYieldsTopicMessages() async throws {
    let transport = TestTransport()
    let client = try PhoenixClient(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    transport.simulateOpen()

    let channel = await client.channel("room:lobby")
    let stream = await channel.messages()
    var iterator = stream.makeAsyncIterator()

    transport.simulateMessage(joinRef: nil, ref: "1", topic: "room:lobby", event: "new_msg", payload: ["body": "hey"])

    let first = await iterator.next()
    #expect(first?.payload[string: "body"] == "hey")
  }

  @Test
  func genericPushDecodeWorks() async throws {
    struct Input: Codable, Sendable { let body: String }
    struct Output: Codable, Sendable { let id: Int }

    let transport = TestTransport()
    let client = try PhoenixClient(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    transport.simulateOpen()

    let channel = await client.channel("room:lobby")

    let joinTask = Task { try await channel.join() }
    try await Task.sleep(for: .milliseconds(10))
    let joinFrame = try #require(transport.lastSentFrame())
    transport.simulateMessage(joinRef: joinFrame.ref, ref: joinFrame.ref, topic: "room:lobby", event: PhoenixSystemEvent.reply.rawValue, payload: ["status": "ok", "response": [:]])
    _ = try await joinTask.value

    let pushTask = Task { try await channel.push(.custom("create"), payload: Input(body: "x"), as: Output.self) }
    try await Task.sleep(for: .milliseconds(10))
    let pushFrame = try #require(transport.lastSentFrame())
    transport.simulateMessage(
      joinRef: joinFrame.ref,
      ref: pushFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": ["id": 7]]
    )

    let decoded = try await pushTask.value
    #expect(decoded.id == 7)
  }
}
