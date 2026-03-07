import Testing
@testable import PhoenixNectar

struct ChannelAsyncTests {
    @Test @MainActor
    func joinAsyncReturnsReplyPayload() async throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        socket.connect()
        transport.simulateOpen()

        let channel = socket.channel("room:lobby")
        let joinTask = Task { try await channel.joinAsync() }

        try await Task.sleep(nanoseconds: 10_000_000)
        let joinFrame = try #require(transport.lastSentFrame())
        #expect(joinFrame.event == ChannelEvent.join)

        transport.simulateMessage(
            joinRef: joinFrame.ref,
            ref: joinFrame.ref,
            topic: "room:lobby",
            event: ChannelEvent.reply,
            payload: ["status": "ok", "response": ["welcome": true]]
        )

        let message = try await joinTask.value
        #expect(message.status == "ok")
        #expect(message.payload[bool: "welcome"] == true)
    }

    @Test @MainActor
    func pushAsyncReturnsReplyPayload() async throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        socket.connect()
        transport.simulateOpen()

        let channel = socket.channel("room:lobby")

        let joinTask = Task { try await channel.joinAsync() }
        try await Task.sleep(nanoseconds: 10_000_000)
        let joinFrame = try #require(transport.lastSentFrame())
        transport.simulateMessage(
            joinRef: joinFrame.ref,
            ref: joinFrame.ref,
            topic: "room:lobby",
            event: ChannelEvent.reply,
            payload: ["status": "ok", "response": [:]]
        )
        _ = try await joinTask.value

        let pushTask = Task {
            try await channel.pushAsync("new_msg", payload: ["body": "hello"], timeout: 1)
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        let pushFrame = try #require(transport.lastSentFrame())
        #expect(pushFrame.event == "new_msg")
        #expect(pushFrame.payload[string: "body"] == "hello")

        transport.simulateMessage(
            joinRef: joinFrame.ref,
            ref: pushFrame.ref,
            topic: "room:lobby",
            event: ChannelEvent.reply,
            payload: ["status": "ok", "response": ["accepted": true]]
        )

        let message = try await pushTask.value
        #expect(message.payload[bool: "accepted"] == true)
    }

    @Test @MainActor
    func pushAsyncThrowsTimeout() async throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        socket.connect()
        transport.simulateOpen()

        let channel = socket.channel("room:lobby")

        let joinTask = Task { try await channel.joinAsync() }
        try await Task.sleep(nanoseconds: 10_000_000)
        let joinFrame = try #require(transport.lastSentFrame())
        transport.simulateMessage(
            joinRef: joinFrame.ref,
            ref: joinFrame.ref,
            topic: "room:lobby",
            event: ChannelEvent.reply,
            payload: ["status": "ok", "response": [:]]
        )
        _ = try await joinTask.value

        let pushTask = Task {
            try await channel.pushAsync("new_msg", payload: [:], timeout: 0.02)
        }

        try await Task.sleep(nanoseconds: 80_000_000)

        do {
            _ = try await pushTask.value
            Issue.record("Expected timeout")
        } catch let error as PushAsyncError {
            guard case .timeout = error else {
                Issue.record("Expected PushAsyncError.timeout, got \(error)")
                return
            }
        }
    }

    @Test @MainActor
    func channelEventStreamEmitsMatchingEvents() async throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        socket.connect()
        transport.simulateOpen()

        let channel = socket.channel("room:lobby")

        let stream = channel.messages(event: "new_msg")
        var iterator = stream.makeAsyncIterator()

        transport.simulateMessage(joinRef: nil, ref: "1", topic: "room:lobby", event: "ignore", payload: [:])
        transport.simulateMessage(joinRef: nil, ref: "2", topic: "room:lobby", event: "new_msg", payload: ["body": "hi"])

        let first = await iterator.next()
        #expect(first?.payload[string: "body"] == "hi")
    }

    @Test @MainActor
    func typedEventAPIsWorkForOnPushAndStreams() async throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        socket.connect()
        transport.simulateOpen()

        let channel = socket.channel("room:lobby")
        let stream = channel.messages(event: .custom("new_msg"))
        var iterator = stream.makeAsyncIterator()

        let bindRef = channel.on(.custom("typed_evt")) { _ in }
        channel.off(.custom("typed_evt"), ref: bindRef)

        let joinTask = Task { try await channel.joinAsync() }
        try await Task.sleep(nanoseconds: 10_000_000)
        let joinFrame = try #require(transport.lastSentFrame())
        transport.simulateMessage(
            joinRef: joinFrame.ref,
            ref: joinFrame.ref,
            topic: "room:lobby",
            event: ChannelEvent.reply,
            payload: ["status": "ok", "response": [:]]
        )
        _ = try await joinTask.value

        let pushTask = Task {
            try await channel.pushAsync(.custom("new_msg"), payload: ["body": "typed"], timeout: 1)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let pushFrame = try #require(transport.lastSentFrame())
        transport.simulateMessage(
            joinRef: joinFrame.ref,
            ref: pushFrame.ref,
            topic: "room:lobby",
            event: ChannelEvent.reply,
            payload: ["status": "ok", "response": ["accepted": true]]
        )

        transport.simulateMessage(joinRef: joinFrame.ref, ref: "5", topic: "room:lobby", event: "new_msg", payload: ["body": "typed"])
        let streamed = await iterator.next()
        #expect(streamed?.payload[string: "body"] == "typed")
        _ = try await pushTask.value
    }

    @Test @MainActor
    func lifecycleMessagesWithOutdatedJoinRefAreDropped() async throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        socket.connect()
        transport.simulateOpen()

        let channel = socket.channel("room:lobby")
        _ = try channel.join()
        try await Task.sleep(nanoseconds: 10_000_000)
        let joinFrame = try #require(transport.lastSentFrame())
        let activeJoinRef = joinFrame.ref

        var replies = 0
        channel.on(ChannelEvent.reply) { _ in
            replies += 1
        }

        transport.simulateMessage(
            joinRef: "outdated-ref",
            ref: "99",
            topic: "room:lobby",
            event: ChannelEvent.reply,
            payload: ["status": "ok", "response": [:]]
        )
        transport.simulateMessage(
            joinRef: activeJoinRef,
            ref: "100",
            topic: "room:lobby",
            event: ChannelEvent.reply,
            payload: ["status": "ok", "response": [:]]
        )
        try await Task.sleep(for: .milliseconds(10))

        #expect(replies == 1)
    }

    @Test @MainActor
    func channelMessageStreamCancellationReleasesBinding() async throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        let channel = socket.channel("room:lobby")

        let baselineBindings = channel.syncBindingsDel.count
        let stream = channel.messages(event: "new_msg")
        let task = Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        #expect(channel.syncBindingsDel.count == baselineBindings + 1)
        task.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(channel.syncBindingsDel.count == baselineBindings)
    }
}
