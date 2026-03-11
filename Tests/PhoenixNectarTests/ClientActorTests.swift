import Foundation
#if canImport(OSLog)
import OSLog
#endif
import Testing
@testable import PhoenixNectar

@Suite(.timeLimit(.minutes(2)))
struct ClientActorTests {
  actor ReconnectAttemptStore {
    private var attempts: [Int] = []

    func append(_ event: ClientMetricEvent) {
      if case .connectionStateChanged(.reconnecting(let attempt, _)) = event {
        attempts.append(attempt)
      }
    }

    func popReconnectAttempt() -> Int? {
      guard !attempts.isEmpty else { return nil }
      return attempts.removeFirst()
    }
  }

  @Test
  func paramsProviderIsAppliedToEndpointQuery() async throws {
    actor URLBox {
      var value: URL?
      func set(_ url: URL) { value = url }
      func get() -> URL? { value }
    }

    let urlBox = URLBox()
    let transport = TestTransport()

    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      connectParamsProvider: {
        [
          "device_id": .string("ios-device-1")
        ]
      },
      transportFactory: { url in
        Task { await urlBox.set(url) }
        return transport
      }
    )

    try await client.connect()

    let url = try #require(await eventually {
      await urlBox.get()
    })
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query["device_id"] == "ios-device-1")
    #expect(query["vsn"] == "2.0.0")
    await client.disconnect()
  }

  @Test
  func authTokenIsSentUsingSecWebSocketProtocolHeader() async throws {
    let transport = TestTransport()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      authTokenProvider: { "1234" },
      transportFactory: { _ in transport }
    )

    try await client.connect()

    let headers = await transport.connectHeaders()
    #expect(headers["Sec-WebSocket-Protocol"] == "phoenix, base64url.bearer.phx.MTIzNA")
    await client.disconnect()
  }

  @Test
  func authTokenHeaderUsesRFC4648Base64URLAlphabet() async throws {
    let transport = TestTransport()
    let token = "9Pym*?Sp~3" // Base64: OVB5bSo/U3B+Mw== contains '/' and '+'
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      authTokenProvider: { token },
      transportFactory: { _ in transport }
    )

    try await client.connect()

    let headers = await transport.connectHeaders()
    #expect(headers["Sec-WebSocket-Protocol"] == "phoenix, base64url.bearer.phx.OVB5bSo_U3B-Mw")
    await client.disconnect()
  }

  @Test
  func socketIsReleasedAfterTerminalTransportClose() async throws {
    final class WeakBox {
      weak var value: AnyObject?
    }

    let transport = TestTransport()
    let box = WeakBox()

    var client: Socket? = try Socket(
      endpoint: "ws://localhost:4000/socket",
      transportFactory: { _ in transport }
    )
    box.value = client

    try await client?.connect()
    await transport.simulateOpen()
    await transport.simulateClose(code: 1006, reason: "lost")

    client = nil

    let released = await eventually(timeout: .milliseconds(200), poll: .milliseconds(10)) {
      box.value == nil ? true : nil
    }
    #expect(released == true)
  }

  @Test
  func channelDescriptorJoinWorks() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let descriptor = ChannelDescriptor(topic: .room("lobby"), params: ["token": "abc", "limit": 5])
    let stream = await transport.sentFrameStream()
    let joinTask = Task { try await client.joinChannel(descriptor) }
    let joinFrame = try await awaitFrame(stream)
    #expect(joinFrame.topic == "room:lobby")
    #expect(joinFrame.payload[string: "token"] == "abc")
    #expect(joinFrame.payload[int: "limit"] == 5)

    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )

    let handle = try await joinTask.value
    #expect(handle.topic == .room("lobby"))
    await client.disconnect()
  }

  @Test
  func joinResponseDecodingWorks() async throws {
    struct JoinResponse: Codable, Sendable {
      let role: String
    }

    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))
    let stream = await transport.sentFrameStream()
    let joinTask = Task {
      let reply = try await channel.join()
      return try reply.response.decode(JoinResponse.self)
    }

    let joinFrame = try await awaitFrame(stream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": ["role": "member"]]
    )

    let decoded = try await joinTask.value
    #expect(decoded.role == "member")
    await client.disconnect()
  }

  @Test
  func typedPushAndSubscribeDescriptorsWork() async throws {
    struct NewMessage: Codable, Sendable { let body: String }
    struct Ack: Codable, Sendable { let accepted: Bool }

    let sendEvent = Push<NewMessage, Ack>("new_msg")
    let recvEvent = Event<NewMessage>("new_msg")

    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))

    let stream = await transport.sentFrameStream()
    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(stream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await joinTask.value

    let typedStream = await channel.subscribe(to: recvEvent)
    var iterator = typedStream.makeAsyncIterator()

    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: "4",
      topic: "room:lobby",
      event: "new_msg",
      payload: ["body": "hello"]
    )

    let next = try await iterator.next()
    #expect(next?.body == "hello")

    let pushTask = Task {
      try await channel.push(sendEvent, payload: NewMessage(body: "hello"))
    }
    let pushFrame = try await awaitFrame(stream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: pushFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": ["accepted": true]]
    )

    let ack = try await pushTask.value
    #expect(ack.accepted == true)

    await client.disconnect()
  }

  @Test
  func binaryBroadcastMessagesAreDeliveredToBinarySubscriptions() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))

    let frameStream = await transport.sentFrameStream()
    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await joinTask.value

    let stream = await channel.subscribeBinary(to: "image:posted")
    var iterator = stream.makeAsyncIterator()
    let payload = Data([0, 1, 2, 3, 255])

    await transport.simulateMessageData(
      binaryBroadcastFrame(topic: "room:lobby", event: "image:posted", payload: payload)
    )

    let received = try #require(await eventually {
      await iterator.next()
    })
    #expect(received == payload)
    await client.disconnect()
  }

  @Test
  func staleMessagesFromSupersededJoinRefAreDropped() async throws {
    struct CapturedLog: Sendable {
      let level: OSLogType
      let category: String
      let message: String
      let metadata: [String: String]
    }

    actor LogStore {
      var events: [CapturedLog] = []
      func append(_ event: CapturedLog) { events.append(event) }
      func all() -> [CapturedLog] { events }
    }

    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    let store = LogStore()
    await client.setLogSinkForTests { level, category, message, metadata in
      Task { await store.append(CapturedLog(level: level, category: category, message: message, metadata: metadata)) }
    }
    try await client.connect()
    await transport.simulateOpen()

    let firstHandle = await client.channel(.room("lobby"))
    let frameStream = await transport.sentFrameStream()
    let firstJoinTask = Task { try await firstHandle.join() }
    let firstJoin = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: firstJoin.joinRef,
      ref: firstJoin.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await firstJoinTask.value

    let secondHandle = await client.channel(.room("lobby"))
    let secondJoinTask = Task { try await secondHandle.join() }
    let secondJoin = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: secondJoin.joinRef,
      ref: secondJoin.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await secondJoinTask.value

    await transport.simulateMessage(
      joinRef: firstJoin.joinRef,
      ref: "stale",
      topic: "room:lobby",
      event: "new_msg",
      payload: ["body": "stale"]
    )
    await transport.simulateMessage(
      joinRef: secondJoin.joinRef,
      ref: "fresh",
      topic: "room:lobby",
      event: "new_msg",
      payload: ["body": "fresh"]
    )

    let staleDrop = try #require(await eventually(timeout: .seconds(1), poll: .milliseconds(10)) {
      let events = await store.all()
      return events.first(where: {
        $0.category == "channel"
          && $0.message == "stale message dropped"
          && $0.metadata["joinRef"] == firstJoin.joinRef
          && $0.metadata["currentJoinRef"] == secondJoin.joinRef
      })
    })
    #expect(staleDrop.metadata["topic"] == "room:lobby")
    #expect(staleDrop.metadata["event"] == "new_msg")

    await client.disconnect()
  }

  @Test
  func binaryReplyPayloadIsPreservedAndDecodable() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))
    let frameStream = await transport.sentFrameStream()
    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await joinTask.value

    let payload = Data([0, 1, 2, 3, 255])
    let pushTask = Task {
      try await channel.pushBinary(
        "binary:upload",
        data: Data([9, 8, 7]),
        policy: RequestPolicy(timeout: .seconds(1))
      )
    }

    let sentBinary = try #require(await eventually {
      await transport.lastSentBinary()
    })
    let sentRef = try #require(binaryPushFrameRef(sentBinary))
    let sentJoinRef = try #require(binaryPushFrameJoinRef(sentBinary))

    await transport.simulateMessageData(
      binaryReplyFrame(joinRef: sentJoinRef, ref: sentRef, topic: "room:lobby", status: "ok", payload: payload)
    )

    let reply = try await pushTask.value
    #expect(reply.binaryResponse == payload)

    let decoded = try reply.decode(Data.self)
    #expect(decoded == payload)

    await client.disconnect()
  }

  @Test
  func metricsHookReceivesStateAndFrameEvents() async throws {
    actor MetricsStore {
      var events: [ClientMetricEvent] = []
      func append(_ event: ClientMetricEvent) { events.append(event) }
      func all() -> [ClientMetricEvent] { events }
    }

    let store = MetricsStore()
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    await client.setMetricsHookForTests { event in
      Task {
        await store.append(event)
      }
    }

    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))

    let frameStream = await transport.sentFrameStream()
    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await joinTask.value

    let events = try #require(await eventually {
      let events = await store.all()
      let hasConnected = events.contains(.connectionStateChanged(.connected))
      let hasReply = events.contains(where: {
        if case .frameReceived(let message) = $0 {
          return message.event == .system(.reply) && message.topic == .room("lobby")
        }
        return false
      })
      return (hasConnected && hasReply) ? events : nil
    })
    #expect(events.contains(.connectionStateChanged(.connecting)))
    #expect(events.contains(.connectionStateChanged(.connected)))
    #expect(events.contains(where: {
      if case .frameSent(_, let topic, let event) = $0 {
        return topic == .room("lobby") && event == .system(.join)
      }
      return false
    }))
    #expect(events.contains(where: {
      if case .frameReceived(let message) = $0 {
        return message.event == .system(.reply) && message.topic == .room("lobby")
      }
      return false
    }))
    await client.disconnect()
  }

  @Test
  func loggerReceivesRuntimeEvents() async throws {
    struct CapturedLog: Sendable {
      let level: OSLogType
      let category: String
      let message: String
      let metadata: [String: String]
    }

    actor LogStore {
      var events: [CapturedLog] = []
      func append(_ event: CapturedLog) { events.append(event) }
      func all() -> [CapturedLog] { events }
    }

    let store = LogStore()
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    await client.setLogSinkForTests { level, category, message, metadata in
      Task { await store.append(CapturedLog(level: level, category: category, message: message, metadata: metadata)) }
    }

    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))
    let frameStream = await transport.sentFrameStream()
    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await joinTask.value

    let events = try #require(await eventually {
      let events = await store.all()
      let hasTransport = events.contains(where: { $0.category == "transport" })
      let hasChannelJoin = events.contains(where: { $0.category == "channel" && $0.message == "join" })
      let hasSend = events.contains(where: { $0.category == "send" })
      return (hasTransport && hasChannelJoin && hasSend) ? events : nil
    })

    let hasConnectRequested = events.contains(where: { $0.category == "transport" && $0.message == "connect requested" })
    let hasSocketOpened = events.contains(where: { $0.category == "transport" && $0.message == "socket opened" })
    let hasLobbyJoin = events.contains(where: { event in
      event.category == "channel"
        && event.message == "join"
        && event.metadata["topic"] == "room:lobby"
    })
    #expect(hasConnectRequested)
    #expect(hasSocketOpened)
    #expect(hasLobbyJoin)

    await client.disconnect()
  }

  @Test
  func connectionStateStreamYieldsTypedStates() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })

    let stream = await client.connectionStateStream()
    var iterator = stream.makeAsyncIterator()

    let initial = await iterator.next()
    #expect(initial == .idle)

    try await client.connect()
    let connecting = await iterator.next()
    #expect(connecting == .connecting)

    await transport.simulateOpen()
    let connected = await iterator.next()
    #expect(connected == .connected)
    await client.disconnect()
  }

  @Test
  func joinAndPushRoundTrip() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })

    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))

    let frameStream = await transport.sentFrameStream()
    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(frameStream)

    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    let joinReply = try await joinTask.value
    #expect(joinReply.status == .ok)

    let pushTask = Task { try await channel.push("new_msg", payload: ["body": "hi"]) }
    let pushFrame = try await awaitFrame(frameStream)

    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: pushFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": ["accepted": true]]
    )

    let reply = try await pushTask.value
    #expect(reply.response[bool: "accepted"] == true)
    await client.disconnect()
  }

  @Test
  func channelMessageStreamYieldsTopicMessages() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let stream = await client.messages(topic: .room("lobby"))
    var iterator = stream.makeAsyncIterator()

    await transport.simulateMessage(joinRef: nil, ref: "1", topic: "room:lobby", event: "new_msg", payload: ["body": "hey"])

    let first = await iterator.next()
    #expect(first?.payload[string: "body"] == "hey")
    #expect(first?.topic == .room("lobby"))
    #expect(first?.event == .named("new_msg"))
    await client.disconnect()
  }

  @Test
  func genericPushDecodeWorks() async throws {
    struct Input: Codable, Sendable { let body: String }
    struct Output: Codable, Sendable { let id: Int }

    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))

    let frameStream = await transport.sentFrameStream()
    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(joinRef: joinFrame.joinRef, ref: joinFrame.ref, topic: "room:lobby", event: PhoenixSystemEvent.reply.rawValue, payload: ["status": "ok", "response": [:]])
    _ = try await joinTask.value

    let pushTask = Task {
      let reply = try await channel.push("create", payload: Input(body: "x"))
      return try reply.response.decode(Output.self)
    }
    let pushFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: pushFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": ["id": 7]]
    )

    let decoded = try await pushTask.value
    #expect(decoded.id == 7)
    await client.disconnect()
  }

  @Test
  func rawPushReplyStatusAndDecodeWork() async throws {
    struct Input: Codable, Sendable { let body: String }
    struct Output: Codable, Sendable { let accepted: Bool }

    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))

    let frameStream = await transport.sentFrameStream()
    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await joinTask.value

    let pushTask = Task {
      let reply = try await channel.push("create", payload: Input(body: "x"))
      return try reply.decode(Output.self)
    }
    let pushFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: pushFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": ["accepted": true]]
    )

    let output = try await pushTask.value
    #expect(output.accepted == true)
    await client.disconnect()
  }

  @Test
  func phoenixEventCanDriveRawPushAndTypedSubscribe() async throws {
    struct Payload: Codable, Sendable { let body: String }
    struct Ack: Codable, Sendable { let accepted: Bool }

    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))
    let frameStream = await transport.sentFrameStream()
    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await joinTask.value

    let stream = await channel.subscribe(to: Event<Payload>("new_msg"))
    var iterator = stream.makeAsyncIterator()

    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: "22",
      topic: "room:lobby",
      event: "new_msg",
      payload: ["body": "hello"]
    )
    let next = try await iterator.next()
    #expect(next?.body == "hello")

    let pushTask = Task {
      let reply = try await channel.push("new_msg", payload: Payload(body: "hi"))
      return try reply.response.decode(Ack.self)
    }
    let pushFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: pushFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": ["accepted": true]]
    )
    let ack = try await pushTask.value
    #expect(ack.accepted == true)
    await client.disconnect()
  }

  @Test
  func joinChannelWithCodableParamsEncodesObjectPayload() async throws {
    struct JoinParams: Codable, Sendable {
      let token: String
      let limit: Int
    }

    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let frameStream = await transport.sentFrameStream()
    let joinTask = Task {
      try await client.joinChannel(.room("lobby"), params: JoinParams(token: "abc", limit: 3))
    }

    let joinFrame = try await awaitFrame(frameStream)
    #expect(joinFrame.topic == "room:lobby")
    #expect(joinFrame.event == PhoenixSystemEvent.join.rawValue)
    #expect(joinFrame.payload[string: "token"] == "abc")
    #expect(joinFrame.payload[int: "limit"] == 3)

    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )

    let handle = try await joinTask.value
    #expect(handle.topic == .room("lobby"))
    await client.disconnect()
  }

  @Test
  func channelEventsAndSubscribeAreTyped() async throws {
    struct NewMessage: Codable, Sendable { let body: String }

    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))

    let messageStream = await client.messages(topic: .room("lobby"))
    var eventIterator = messageStream.makeAsyncIterator()

    let typedStream = await channel.subscribe(to: Event<NewMessage>("new_msg"))
    var typedIterator = typedStream.makeAsyncIterator()

    await transport.simulateMessage(joinRef: nil, ref: "1", topic: "room:lobby", event: "new_msg", payload: ["body": "hello"]) 

    let event = await eventIterator.next()
    #expect(event?.event == .named("new_msg"))
    #expect(event?.topic == .room("lobby"))

    let typed = try await typedIterator.next()
    #expect(typed?.body == "hello")
    await client.disconnect()
  }

  @Test
  func joinTimeoutRollsBackJoinRefAndNextPushHasNoJoinRef() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))

    await #expect(throws: PhoenixError.self) {
      _ = try await channel.join(policy: RequestPolicy(timeout: .milliseconds(20)))
    }

    let frameStream = await transport.sentFrameStream()
    let pushTask = Task {
      try await channel.push(
        "new_msg",
        payload: ["body": "x"],
        policy: RequestPolicy(timeout: .seconds(1))
      )
    }
    let pushFrame = try await awaitFrame(frameStream)
    #expect(pushFrame.event == "new_msg")
    #expect(pushFrame.joinRef == nil)

    await transport.simulateMessage(
      joinRef: nil,
      ref: pushFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await pushTask.value
    await client.disconnect()
  }

  @Test
  func reconnectAttemptCounterIncrementsAcrossReconnects() async throws {
    let transport = TestTransport()
    let scheduler = TestScheduler()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      scheduler: scheduler,
      transportFactory: { _ in transport }
    )
    await client.setReconnectAfterForTests { _ in .seconds(1) }

    let attemptStore = ReconnectAttemptStore()
    await client.setMetricsHookForTests { event in
      Task { await attemptStore.append(event) }
    }

    try await client.connect()
    await transport.simulateOpen()

    await transport.simulateClose(code: 999, reason: "drop-1")
    let firstAttempt = await waitForReconnectAttempt(attemptStore)
    await scheduler.fireOnceScheduled()

    await transport.simulateClose(code: 999, reason: "drop-2")
    let secondAttempt = await waitForReconnectAttempt(attemptStore)
    await scheduler.fireOnceScheduled()

    #expect(firstAttempt == 1)
    #expect(secondAttempt == 2)
    await client.disconnect()
  }

  @Test
  func joinedChannelsAreRejoinedAfterReconnect() async throws {
    let transport = TestTransport()
    let scheduler = TestScheduler()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      scheduler: scheduler,
      transportFactory: { _ in transport }
    )
    await client.setReconnectAfterForTests { _ in .seconds(1) }

    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))
    let frameStream = await transport.sentFrameStream()
    let initialJoinTask = Task { try await channel.join() }
    let firstJoin = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: firstJoin.joinRef,
      ref: firstJoin.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await initialJoinTask.value

    let connectStream = await transport.connectStream()
    await transport.simulateClose(code: 999, reason: "drop")
    try await awaitConnect(connectStream, count: 2, scheduler: scheduler)
    await transport.simulateOpen()
    let rejoinFrame = try await awaitFrame(
      frameStream,
      matching: { $0.topic == "room:lobby" && $0.event == PhoenixSystemEvent.join.rawValue }
    )

    await transport.simulateMessage(
      joinRef: rejoinFrame.joinRef,
      ref: rejoinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )

    let pushTask = Task {
      try await channel.push(
        "new_msg",
        payload: ["body": "hi"],
        policy: RequestPolicy(timeout: .seconds(1))
      )
    }
    let pushFrame = try await awaitFrame(frameStream)
    #expect(pushFrame.joinRef != nil)
    await transport.simulateMessage(
      joinRef: rejoinFrame.joinRef,
      ref: pushFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await pushTask.value
    await client.disconnect()
  }

  @Test
  func pingUsesHeartbeatRoundTrip() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })

    try await client.connect()
    await transport.simulateOpen()

    let frameStream = await transport.sentFrameStream()
    let pingTask = Task {
      try await client.ping(policy: RequestPolicy(timeout: .seconds(1)))
    }
    let frame = try await awaitFrame(frameStream)
    #expect(frame.topic == "phoenix")
    #expect(frame.event == PhoenixSystemEvent.heartbeat.rawValue)

    await transport.simulateMessage(
      joinRef: nil,
      ref: frame.ref,
      topic: "phoenix",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )

    let duration = try await pingTask.value
    #expect(duration >= .zero)
    await client.disconnect()
  }

  @Test
  func heartbeatTimeoutSchedulesReconnect() async throws {
    let transport = TestTransport()
    let scheduler = TestScheduler()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      scheduler: scheduler,
      transportFactory: { _ in transport }
    )
    await client.setReconnectAfterForTests { _ in .seconds(1) }
    await client.setHeartbeatIntervalForTests(.milliseconds(10))

    try await client.connect()
    await transport.simulateOpen()
    #expect(await transport.connectCallCount() == 1)

    let firstHeartbeat = try #require(await eventually {
      await scheduler.fireScheduled()
      return await transport.lastSentFrame()
    })
    #expect(firstHeartbeat.topic == "phoenix")
    #expect(firstHeartbeat.event == PhoenixSystemEvent.heartbeat.rawValue)

    let connectStream = await transport.connectStream()
    await scheduler.fireScheduled()
    try await awaitConnect(connectStream, count: 2, scheduler: scheduler)

    let reconnectCalls = await transport.connectCallCount()
    #expect(reconnectCalls >= 2)
    await client.disconnect()
  }

  @Test
  func reconnectIsScheduledAfterTransportError() async throws {
    let transport = TestTransport()
    let scheduler = TestScheduler()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      scheduler: scheduler,
      transportFactory: { _ in transport }
    )
    await client.setReconnectAfterForTests { _ in .seconds(1) }
    let attemptStore = ReconnectAttemptStore()
    await client.setMetricsHookForTests { event in
      Task { await attemptStore.append(event) }
    }

    try await client.connect()
    await transport.simulateOpen()
    #expect(await transport.connectCallCount() == 1)

    let connectStream = await transport.connectStream()
    await transport.simulateError("boom")
    try await awaitConnect(connectStream, count: 2, scheduler: scheduler)

    let reconnectCalls = await transport.connectCallCount()
    let attempt = try #require(await eventually {
      await attemptStore.popReconnectAttempt()
    })
    #expect(reconnectCalls >= 2)
    #expect(attempt == 1)
    await client.disconnect()
  }

  @Test
  func timedOutBufferedPushIsRemovedAndDoesNotFlushLater() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    let channel = await client.channel(.room("lobby"))

    let pushTask = Task {
      try await channel.push(
        "new_msg",
        payload: ["body": "ghost"],
        policy: RequestPolicy(timeout: .milliseconds(40), retries: 0, retryBackoff: { _ in .zero })
      )
    }

    await #expect(throws: PhoenixError.self) {
      _ = try await pushTask.value
    }

    try await client.connect()
    await transport.simulateOpen()

    #expect(await transport.sentFrameCount() == 0)
    await client.disconnect()
  }

  @Test
  func malformedInboundFrameTriggersReconnectPath() async throws {
    let transport = TestTransport()
    let scheduler = TestScheduler()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      scheduler: scheduler,
      transportFactory: { _ in transport }
    )
    await client.setReconnectAfterForTests { _ in .seconds(1) }

    try await client.connect()
    await transport.simulateOpen()

    let connectStream = await transport.connectStream()
    await transport.simulateText("not-json")
    try await awaitConnect(connectStream, count: 2, scheduler: scheduler)

    let reconnectCalls = await transport.connectCallCount()
    #expect(reconnectCalls >= 2)
    await client.disconnect()
  }

  @Test
  func malformedBinaryPushFrameTriggersReconnectPath() async throws {
    let transport = TestTransport()
    let scheduler = TestScheduler()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      scheduler: scheduler,
      transportFactory: { _ in transport }
    )
    await client.setReconnectAfterForTests { _ in .seconds(1) }

    try await client.connect()
    await transport.simulateOpen()

    let connectStream = await transport.connectStream()
    await transport.simulateMessageData(Data([0, 0, 0]))
    try await awaitConnect(connectStream, count: 2, scheduler: scheduler)

    let reconnectCalls = await transport.connectCallCount()
    #expect(reconnectCalls >= 2)
    await client.disconnect()
  }

  @Test
  func malformedBinaryReplyFrameTriggersReconnectPath() async throws {
    let transport = TestTransport()
    let scheduler = TestScheduler()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      scheduler: scheduler,
      transportFactory: { _ in transport }
    )
    await client.setReconnectAfterForTests { _ in .seconds(1) }

    try await client.connect()
    await transport.simulateOpen()

    let connectStream = await transport.connectStream()
    await transport.simulateMessageData(Data([1, 0, 0]))
    try await awaitConnect(connectStream, count: 2, scheduler: scheduler)

    let reconnectCalls = await transport.connectCallCount()
    #expect(reconnectCalls >= 2)
    await client.disconnect()
  }

  @Test
  func pushDoesNotRetryOnServerError() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))
    let frameStream = await transport.sentFrameStream()
    let joinTask = Task { try await channel.join() }
    let joinFrame = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: joinFrame.joinRef,
      ref: joinFrame.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await joinTask.value

    let pushBaseline = await transport.sentFrameCount()
    let retryingPolicy = RequestPolicy(timeout: .seconds(1), retries: 3, retryBackoff: { _ in .zero })
    let pushTask = Task {
      try await channel.push("new_msg", payload: ["body": "x"], policy: retryingPolicy)
    }

    let first = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: first.joinRef,
      ref: first.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "error", "response": ["reason": "bad request"]]
    )

    await #expect(throws: PhoenixError.self) {
      _ = try await pushTask.value
    }
    #expect(await transport.sentFrameCount() == pushBaseline + 1)
    await client.disconnect()
  }

  @Test
  func failedRejoinIsRetriedAndChannelIntentIsKept() async throws {
    let transport = TestTransport()
    let scheduler = TestScheduler()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      scheduler: scheduler,
      transportFactory: { _ in transport }
    )
    await client.setReconnectAfterForTests { _ in .seconds(1) }
    await client.setDefaultRequestPolicyForTests(.init(timeout: .milliseconds(30), retries: 0, retryBackoff: { _ in .zero }))

    try await client.connect()
    await transport.simulateOpen()

    let channel = await client.channel(.room("lobby"))
    let frameStream = await transport.sentFrameStream()
    let initialJoinTask = Task { try await channel.join() }
    let initialJoin = try await awaitFrame(frameStream)
    await transport.simulateMessage(
      joinRef: initialJoin.joinRef,
      ref: initialJoin.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    _ = try await initialJoinTask.value

    let connectStream = await transport.connectStream()
    await transport.simulateClose(code: 999, reason: "drop")
    try await awaitConnect(connectStream, count: 2, scheduler: scheduler)
    await transport.simulateOpen()

    let firstRejoin = try await awaitFrame(frameStream)
    #expect(firstRejoin.event == PhoenixSystemEvent.join.rawValue)

    await transport.simulateMessage(
      joinRef: firstRejoin.joinRef,
      ref: firstRejoin.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "error", "response": ["reason": "transient"]]
    )

    // Keep firing the scheduler until the retry rejoin is sent.
    let secondRejoin: SentFrame = try await withThrowingTaskGroup(of: SentFrame.self) { group in
      group.addTask {
        for await frame in frameStream {
          if frame.event == PhoenixSystemEvent.join.rawValue { return frame }
        }
        throw PhoenixError.timeout
      }
      group.addTask {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
          await scheduler.fireOnceScheduled()
          try await Task.sleep(for: .milliseconds(5))
        }
        throw PhoenixError.timeout
      }
      let result = try await group.next()!
      group.cancelAll()
      return result
    }
    #expect(secondRejoin.event == PhoenixSystemEvent.join.rawValue)
    await client.disconnect()
  }

  @Test
  func offlineBufferLimitDropsOldestFrames() async throws {
    let transport = TestTransport()
    let client = try Socket(endpoint: "ws://localhost:4000/socket", transportFactory: { _ in transport })
    await client.setBufferingForTests(limit: 2, binaryLimit: 2, policy: .dropOldest)

    // Track buffered and dropped events via a stream so we can synchronize without polling.
    let (metricStream, metricContinuation) = AsyncStream<ClientMetricEvent>.makeStream(bufferingPolicy: .unbounded)
    await client.setMetricsHookForTests { event in
      metricContinuation.yield(event)
    }
    let channel = await client.channel(.room("lobby"))

    let policy = RequestPolicy(timeout: .milliseconds(400), retries: 0, retryBackoff: { _ in .zero })

    // Use the metric stream to ensure each push is buffered before starting the next,
    // guaranteeing deterministic ordering in the buffer.
    var metricIterator = metricStream.makeAsyncIterator()

    let t1 = Task { try await channel.push("new_msg", payload: ["body": "one"], policy: policy) }
    // Wait for "one" to be buffered.
    while let event = await metricIterator.next() {
      if case .frameBuffered = event { break }
    }

    let t2 = Task { try await channel.push("new_msg", payload: ["body": "two"], policy: policy) }
    // Wait for "two" to be buffered.
    while let event = await metricIterator.next() {
      if case .frameBuffered = event { break }
    }

    let t3 = Task { try await channel.push("new_msg", payload: ["body": "three"], policy: policy) }
    // Wait for "three" to be buffered AND "one" to be dropped (buffer limit = 2).
    var sawBuffered = false
    var sawDropped = false
    while let event = await metricIterator.next() {
      if case .frameBuffered = event { sawBuffered = true }
      if case .frameDropped = event { sawDropped = true }
      if sawBuffered && sawDropped { break }
    }

    try await client.connect()
    await transport.simulateOpen()

    let frameStream = await transport.sentFrameStream()
    let frame0 = try await awaitFrame(frameStream)
    let frame1 = try await awaitFrame(frameStream)

    #expect(frame0.payload[string: "body"] == "two")
    #expect(frame1.payload[string: "body"] == "three")

    await transport.simulateMessage(
      joinRef: frame0.joinRef,
      ref: frame0.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )
    await transport.simulateMessage(
      joinRef: frame1.joinRef,
      ref: frame1.ref,
      topic: "room:lobby",
      event: PhoenixSystemEvent.reply.rawValue,
      payload: ["status": "ok", "response": [:]]
    )

    _ = try await t2.value
    _ = try await t3.value
    await #expect(throws: PhoenixError.self) {
      _ = try await t1.value
    }
    await client.disconnect()
  }

  @Test
  func pushCancelledBeforeReplyDoesNotCrash() async throws {
    let transport = TestTransport()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      configuration: .init(defaultRequestPolicy: RequestPolicy(timeout: .seconds(2))),
      transportFactory: { _ in transport }
    )
    try await client.connect()
    await transport.simulateOpen()

    // Reply to the join asynchronously so joinChannel can complete.
    Task {
      let frame = try? await eventually(timeout: .seconds(1)) {
        await transport.lastSentFrame()
      }
      guard let frame else { return }
      await transport.simulateMessage(
        joinRef: frame.joinRef,
        ref: frame.ref,
        topic: "room:lobby",
        event: PhoenixSystemEvent.reply.rawValue,
        payload: ["status": "ok", "response": [:]]
      )
    }

    let channel = try await client.joinChannel("room:lobby")

    // Start a push, wait for the frame to be sent, then cancel.
    let pushTask = Task {
      try await channel.push("msg:new", payload: ["body": "hello"])
    }

    // Wait for the push frame to appear on the transport.
    _ = await eventually(timeout: .seconds(1)) {
      let count = await transport.sentFrameCount()
      return count >= 2 ? true : nil  // join + push
    }

    pushTask.cancel()

    // Should complete with either CancellationError or timeout — never crash.
    do {
      _ = try await pushTask.value
    } catch is CancellationError {
      // Expected path.
    } catch let error as PhoenixError where error == .timeout {
      // Also acceptable — cancellation raced with timeout.
    }

    await client.disconnect()
  }

  @Test
  func serverInitiatedCleanCloseReconnectsByDefault() async throws {
    let transport = TestTransport()
    let scheduler = TestScheduler()
    let store = ReconnectAttemptStore()
    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      scheduler: scheduler,
      transportFactory: { _ in transport }
    )
    await client.setMetricsHook { event in
      Task { await store.append(event) }
    }

    try await client.connect()
    await transport.simulateOpen()

    // Server sends a clean 1000 close (e.g. during deployment).
    await transport.simulateClose(code: 1000, reason: "server restart")

    // With default reconnectOnCleanClose=true, a reconnect should be scheduled.
    let attempt = await waitForReconnectAttempt(store)
    #expect(attempt == 1)

    await client.disconnect()
  }

  @Test
  func serverInitiatedCleanCloseDoesNotReconnectWhenDisabled() async throws {
    let transport = TestTransport()
    let scheduler = TestScheduler()

    let client = try Socket(
      endpoint: "ws://localhost:4000/socket",
      configuration: .init(
        connectionPolicy: ConnectionPolicy(reconnectOnCleanClose: false)
      ),
      scheduler: scheduler,
      transportFactory: { _ in transport }
    )

    try await client.connect()
    await transport.simulateOpen()

    // Server sends a clean 1000 close.
    await transport.simulateClose(code: 1000, reason: "server restart")

    // No reconnect should be scheduled.
    #expect(!scheduler.hasPendingOnce)

    await client.disconnect()
  }
}

private extension Socket {
  func setLogSinkForTests(
    _ sink: (@Sendable (OSLogType, String, String, [String: String]) -> Void)?
  ) async {
    setLogSink(sink)
  }

  func setReconnectAfterForTests(_ value: @escaping @Sendable (Int) -> Duration) async {
    let current = connectionPolicy
    replaceConfiguration(
      .init(
        vsn: vsn,
        headers: headers,
        defaultRequestPolicy: defaultRequestPolicy,
        connectionPolicy: ConnectionPolicy(
          heartbeatInterval: current.heartbeatInterval,
          reconnectBackoff: value
        ),
        outboundBufferLimit: outboundBufferLimit,
        binaryOutboundBufferLimit: binaryOutboundBufferLimit,
        bufferOverflowPolicy: bufferOverflowPolicy
      )
    )
  }

  func setHeartbeatIntervalForTests(_ value: Duration) async {
    replaceConfiguration(
      .init(
        vsn: vsn,
        headers: headers,
        defaultRequestPolicy: defaultRequestPolicy,
        connectionPolicy: ConnectionPolicy(
          heartbeatInterval: value,
          reconnectBackoff: connectionPolicy.reconnectBackoff
        ),
        outboundBufferLimit: outboundBufferLimit,
        binaryOutboundBufferLimit: binaryOutboundBufferLimit,
        bufferOverflowPolicy: bufferOverflowPolicy
      )
    )
  }

  func setMetricsHookForTests(_ hook: ClientMetricsHook?) async {
    setMetricsHook(hook)
  }

  func setDefaultRequestPolicyForTests(_ value: RequestPolicy) async {
    replaceConfiguration(
      .init(
        vsn: vsn,
        headers: headers,
        defaultRequestPolicy: value,
        connectionPolicy: connectionPolicy,
        outboundBufferLimit: outboundBufferLimit,
        binaryOutboundBufferLimit: binaryOutboundBufferLimit,
        bufferOverflowPolicy: bufferOverflowPolicy
      )
    )
  }

  func setBufferingForTests(limit: Int, binaryLimit: Int, policy: BufferOverflowPolicy) async {
    replaceConfiguration(
      .init(
        vsn: vsn,
        headers: headers,
        defaultRequestPolicy: defaultRequestPolicy,
        connectionPolicy: connectionPolicy,
        outboundBufferLimit: limit,
        binaryOutboundBufferLimit: binaryLimit,
        bufferOverflowPolicy: policy
      )
    )
  }
}

/// Awaits the next frame on a pre-registered stream. No polling.
private func awaitFrame(
  _ stream: AsyncStream<SentFrame>,
  timeout: Duration = .seconds(1)
) async throws -> SentFrame {
  try await withThrowingTaskGroup(of: SentFrame.self) { group in
    group.addTask {
      for await frame in stream { return frame }
      throw PhoenixError.timeout
    }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw PhoenixError.timeout
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}

/// Awaits a frame matching a predicate on a pre-registered stream.
private func awaitFrame(
  _ stream: AsyncStream<SentFrame>,
  matching predicate: @escaping @Sendable (SentFrame) -> Bool,
  timeout: Duration = .seconds(1)
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
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}

/// Awaits the Nth connect call on a pre-registered stream. No polling.
private func awaitConnect(
  _ stream: AsyncStream<Int>,
  count: Int,
  scheduler: TestScheduler,
  timeout: Duration = .seconds(1)
) async throws {
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      for await callCount in stream {
        if callCount >= count { return }
      }
      throw PhoenixError.timeout
    }
    group.addTask {
      // Keep firing the scheduler to allow reconnect callbacks to execute.
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
        await scheduler.fireOnceScheduled()
        try await Task.sleep(for: .milliseconds(1))
      }
      throw PhoenixError.timeout
    }
    _ = try await group.next()
    group.cancelAll()
  }
}

private func waitForReconnectAttempt(
  _ store: ClientActorTests.ReconnectAttemptStore,
  timeout: Duration = .seconds(1)
) async -> Int? {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while clock.now < deadline {
    if let attempt = await store.popReconnectAttempt() {
      return attempt
    }
    await Task.yield()
  }
  return nil
}

private func binaryBroadcastFrame(topic: String, event: String, payload: Data) -> Data {
  let topicBytes = Array(topic.utf8)
  let eventBytes = Array(event.utf8)
  var data = Data()
  data.append(2)
  data.append(UInt8(topicBytes.count))
  data.append(UInt8(eventBytes.count))
  data.append(contentsOf: topicBytes)
  data.append(contentsOf: eventBytes)
  data.append(payload)
  return data
}

private func binaryReplyFrame(joinRef: String, ref: String, topic: String, status: String, payload: Data) -> Data {
  let joinRefBytes = Array(joinRef.utf8)
  let refBytes = Array(ref.utf8)
  let topicBytes = Array(topic.utf8)
  let statusBytes = Array(status.utf8)

  var data = Data()
  data.append(1)
  data.append(UInt8(joinRefBytes.count))
  data.append(UInt8(refBytes.count))
  data.append(UInt8(topicBytes.count))
  data.append(UInt8(statusBytes.count))
  data.append(contentsOf: joinRefBytes)
  data.append(contentsOf: refBytes)
  data.append(contentsOf: topicBytes)
  data.append(contentsOf: statusBytes)
  data.append(payload)
  return data
}

private func binaryPushFrameJoinRef(_ data: Data) -> String? {
  let bytes = [UInt8](data)
  guard bytes.count >= 5, bytes[0] == 0 else { return nil }
  let joinRefLen = Int(bytes[1])
  let offset = 5
  guard bytes.count >= offset + joinRefLen else { return nil }
  return String(decoding: bytes[offset..<(offset + joinRefLen)], as: UTF8.self)
}

private func binaryPushFrameRef(_ data: Data) -> String? {
  let bytes = [UInt8](data)
  guard bytes.count >= 5, bytes[0] == 0 else { return nil }
  let joinRefLen = Int(bytes[1])
  let refLen = Int(bytes[2])
  let offset = 5 + joinRefLen
  guard bytes.count >= offset + refLen else { return nil }
  return String(decoding: bytes[offset..<(offset + refLen)], as: UTF8.self)
}

private func eventually<T>(
  timeout: Duration = .seconds(1),
  poll: Duration = .milliseconds(2),
  _ operation: @escaping () async -> T?
) async -> T? {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while clock.now < deadline {
    if let value = await operation() {
      return value
    }
    try? await Task.sleep(for: poll)
  }
  return nil
}
