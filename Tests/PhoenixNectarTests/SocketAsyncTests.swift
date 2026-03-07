import Testing
@testable import PhoenixNectar

struct SocketAsyncTests {
    @Test @MainActor
    func socketMessageStreamYieldsInboundMessages() async throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        socket.connect()
        transport.simulateOpen()

        let stream = socket.messages()
        var iterator = stream.makeAsyncIterator()

        transport.simulateMessage(joinRef: nil, ref: "1", topic: "news", event: "headline", payload: ["title": "Phoenix"])

        let first = await iterator.next()
        #expect(first?.topic == "news")
        #expect(first?.event == "headline")
        #expect(first?.payload[string: "title"] == "Phoenix")
    }

    @Test @MainActor
    func socketBuildsEndpointWithVsnAndParams() throws {
        let socket = try Socket("https://example.com/socket", paramsClosure: { ["token": "abc123"] }, vsn: "2.0.0")
        let endpoint = socket.endPointUrl.absoluteString
        #expect(endpoint.contains("/websocket"))
        #expect(endpoint.contains("vsn=2.0.0"))
        #expect(endpoint.contains("token=abc123"))
    }

    @Test @MainActor
    func socketReconnectsAfterAbnormalCloseStatus() throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        socket.skipHeartbeat = true
        socket.reconnectAfter = { _ in 0.01 }
        socket.connect()
        transport.simulateOpen()

        transport.disconnect(code: Socket.CloseCode.abnormal.rawValue, reason: "drop")

        #expect(socket.closeStatus.shouldReconnect == true)
    }

    @Test @MainActor
    func heartbeatTimeoutTriggersAbnormalCloseAndReconnectSchedule() async throws {
        let scheduler = ManualScheduler()
        let transport = TestTransport()
        let socket = try Socket(
            endPoint: "ws://localhost:4000/socket",
            transport: { _ in transport },
            scheduler: scheduler
        )
        socket.heartbeatInterval = 30
        socket.skipHeartbeat = false
        socket.reconnectAfter = { _ in 1 }
        socket.connect()
        transport.simulateOpen()
        try await Task.sleep(for: .milliseconds(10))

        await scheduler.fireAll() // sends heartbeat (pending set)
        await scheduler.fireAll() // next heartbeat tick => timeout
        try await Task.sleep(for: .milliseconds(10))

        #expect(socket.closeStatus.shouldReconnect == true)
    }

    @Test @MainActor
    func socketInitThrowsForMalformedEndpoint() {
        do {
            _ = try Socket("http://[::1")
            Issue.record("Expected malformed endpoint error")
        } catch SocketError.malformedEndpoint {
            // expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test @MainActor
    func socketMessageStreamCancellationReleasesCallback() async throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        socket.connect()
        transport.simulateOpen()

        #expect(socket.stateChangeCallbacks.message.isEmpty)
        let stream = socket.messages()
        let task = Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        #expect(socket.stateChangeCallbacks.message.count == 1)
        task.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(socket.stateChangeCallbacks.message.isEmpty)
    }
}
