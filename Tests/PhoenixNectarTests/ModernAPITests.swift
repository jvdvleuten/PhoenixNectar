import Foundation
import Testing
@testable import PhoenixNectar

@Suite(.timeLimit(.minutes(2)))
struct ModernAPITests {
  enum ChatRoom {
    static func topic(id: String) -> String { "chat:\(id)" }
    static let sendMessage = Push<SendMessage, SendAck>("message:send")
    static let messagePosted = Event<MessagePosted>("message:posted")
  }

  struct SendMessage: Codable, Sendable {
    let body: String
  }

  struct SendAck: Codable, Sendable {
    let accepted: Bool
  }

  struct MessagePosted: Codable, Sendable {
    let body: String
  }

  @Test
  func typedTopicAndCatalogBasedPushAndSubscribeWork() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let frames = await transport.sentFrameStream()
    let joinTask = Task { try await client.joinChannel(ChatRoom.topic(id: "lobby")) }
    let joinFrame = try await awaitFrame(frames)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "chat:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    let channel = try await joinTask.value

    let stream = await channel.subscribe(to: ChatRoom.messagePosted)
    var iterator = stream.makeAsyncIterator()

    await transport.simulateMessage(
      joinRef: nil,
      ref: "1",
      topic: "chat:lobby",
      event: "message:posted",
      payload: ["body": "hello"]
    )

    let posted = try await iterator.next()
    #expect(posted?.body == "hello")

    let pushTask = Task {
      try await channel.push(ChatRoom.sendMessage, payload: SendMessage(body: "hi"))
    }

    let pushFrame = try await awaitFrame(frames)
    await transport.simulateMessage(
      joinRef: pushFrame.joinRef,
      ref: pushFrame.ref,
      topic: "chat:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": ["accepted": true]]
    )

    let ack = try await pushTask.value
    #expect(ack.accepted == true)
  }

  @Test
  func requestPolicyRetriesAfterTimeout() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let frames = await transport.sentFrameStream()
    let channel = await client.channel(.room("lobby"))

    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(frames)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await joinTask.value

    let policy = RequestPolicy(timeout: .milliseconds(100), retries: 1, retryBackoff: { _ in .zero })
    let pushTask = Task {
      try await channel.push("message:send", payload: ["body": "retry"], policy: policy)
    }

    let first = try await awaitFrame(frames, matching: { $0.event == "message:send" })
    #expect(first.event == "message:send")

    let second = try await awaitFrame(frames, matching: { $0.event == "message:send" && $0.ref != first.ref })
    #expect(second.event == "message:send")

    await transport.simulateMessage(
      joinRef: second.joinRef,
      ref: second.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )

    let reply = try await pushTask.value
    #expect(reply.status == .ok)
  }

  @Test
  func socketFrameRoundTripsAcrossGeneratedPayloads() throws {
    var rng = LCRNG(state: 0xDEADBEEF)

    for index in 0..<128 {
      let payload = makePayload(depth: 2, rng: &rng)
      let frame = SocketFrame(
        joinRef: index.isMultiple(of: 2) ? "join-\(index)" : nil,
        ref: "\(index)",
        topic: "room:\(index % 7)",
        event: index.isMultiple(of: 3) ? "new_msg" : PhoenixSystemEvent.reply.rawValue,
        payload: payload
      )

    let data = try Defaults.encodeFrame(frame)
    let decoded = try Defaults.decodeFrame(data)
    #expect(decoded == frame)
    }
  }
}

private struct LCRNG {
  var state: UInt64

  mutating func next() -> UInt64 {
    state = 6364136223846793005 &* state &+ 1442695040888963407
    return state
  }

  mutating func nextInt(_ upperBound: Int) -> Int {
    Int(next() % UInt64(upperBound))
  }
}

private func makePayload(depth: Int, rng: inout LCRNG) -> Payload {
  let count = 1 + rng.nextInt(4)
  var payload: Payload = [:]

  for index in 0..<count {
    payload["k\(index)"] = makeValue(depth: depth, rng: &rng)
  }

  return payload
}

private func makeValue(depth: Int, rng: inout LCRNG) -> PhoenixValue {
  if depth == 0 {
    switch rng.nextInt(5) {
    case 0: return .bool(rng.nextInt(2) == 0)
    case 1: return .int(rng.nextInt(10_000))
    case 2: return .double(Double(rng.nextInt(10_000)) + 0.5)
    case 3: return .string("v\(rng.nextInt(10_000))")
    default: return .null
    }
  }

  switch rng.nextInt(7) {
  case 0: return .bool(rng.nextInt(2) == 0)
  case 1: return .int(rng.nextInt(10_000))
  case 2: return .double(Double(rng.nextInt(10_000)) + 0.5)
  case 3: return .string("v\(rng.nextInt(10_000))")
  case 4:
    let items = (0..<(1 + rng.nextInt(3))).map { _ in
      makeValue(depth: depth - 1, rng: &rng)
    }
    return .array(items)
  case 5:
    return .object(makePayload(depth: depth - 1, rng: &rng))
  default:
    return .null
  }
}

private func awaitFrame(
  _ stream: AsyncStream<SentFrame>,
  timeout: Duration = .seconds(1)
) async throws -> SentFrame {
  try await withThrowingTaskGroup(of: SentFrame.self) { group in
    group.addTask {
      var iterator = stream.makeAsyncIterator()
      guard let frame = await iterator.next() else { throw PhoenixError.timeout }
      return frame
    }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw PhoenixError.timeout
    }
    let value = try await group.next()!
    group.cancelAll()
    return value
  }
}

private func awaitFrame(
  _ stream: AsyncStream<SentFrame>,
  timeout: Duration = .seconds(1),
  matching predicate: @escaping @Sendable (SentFrame) -> Bool
) async throws -> SentFrame {
  try await withThrowingTaskGroup(of: SentFrame.self) { group in
    group.addTask {
      for await frame in stream {
        if predicate(frame) { return frame }
      }
      throw PhoenixError.timeout
    }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw PhoenixError.timeout
    }
    let value = try await group.next()!
    group.cancelAll()
    return value
  }
}
