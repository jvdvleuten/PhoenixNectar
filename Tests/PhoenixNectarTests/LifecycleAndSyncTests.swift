import Testing
@testable import PhoenixNectar

@MainActor
struct LifecycleAndSyncTests {
    @Test
    func socketChannelCollectionMutatesDeterministically() throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        let channel = socket.channel("room:lobby")
        #expect(socket.channels.count == 1)
        socket.remove(channel)
        #expect(socket.channels.count == 0)
    }

    @Test
    func channelLeaveRemovesSocketStateCallbacks() async throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        let channel = socket.channel("room:lobby")
        _ = try channel.join()
        #expect(socket.stateChangeCallbacks.open.count > 0)
        #expect(socket.stateChangeCallbacks.error.count > 0)
        _ = channel.leave()
        socket.remove(channel)
        #expect(socket.channels.count == 0)
    }

    @Test
    func channelJoinThrowsWhenJoiningTwice() throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        let channel = socket.channel("room:lobby")

        _ = try channel.join()

        do {
            _ = try channel.join()
            Issue.record("Expected ChannelError.alreadyJoined")
        } catch ChannelError.alreadyJoined {
            // expected
        }
    }

    @Test
    func channelSchedulesRejoinAfterErrorWhenSocketConnected() async throws {
        let scheduler = ManualScheduler()
        let transport = TestTransport()
        let socket = try Socket(
            endPoint: "ws://localhost:4000/socket",
            transport: { _ in transport },
            scheduler: scheduler
        )
        socket.rejoinAfter = { _ in 0.01 }
        socket.connect()
        transport.simulateOpen()

        let channel = socket.channel("room:lobby")
        _ = try channel.join()
        try await Task.sleep(for: .milliseconds(10))
        let joinFrame = try #require(transport.lastSentFrame())

        transport.simulateMessage(
            joinRef: joinFrame.ref,
            ref: joinFrame.ref,
            topic: "room:lobby",
            event: ChannelEvent.reply,
            payload: ["status": "ok", "response": [:]]
        )
        try await Task.sleep(for: .milliseconds(10))
        #expect(channel.isJoined)

        channel.trigger(event: ChannelEvent.error, payload: [:])
        #expect(channel.isErrored)
        let preRejoinJoinCount = transport.sentTexts.compactMap {
            guard let data = $0.data(using: .utf8),
                  let frame = try? Defaults.decodeFrame(data)
            else { return nil }
            return frame.event == ChannelEvent.join ? 1 : 0
        }.reduce(0, +)
        await scheduler.fireAll()
        let postRejoinJoinCount = transport.sentTexts.compactMap {
            guard let data = $0.data(using: .utf8),
                  let frame = try? Defaults.decodeFrame(data)
            else { return nil }
            return frame.event == ChannelEvent.join ? 1 : 0
        }.reduce(0, +)
        #expect(postRejoinJoinCount == preRejoinJoinCount + 1)
    }

    @Test
    func channelPushThrowsBeforeJoin() throws {
        let transport = TestTransport()
        let socket = try Socket(endPoint: "ws://localhost:4000/socket", transport: { _ in transport })
        let channel = socket.channel("room:lobby")

        do {
            _ = try channel.push("new_msg", payload: [:])
            Issue.record("Expected ChannelError.pushBeforeJoin")
        } catch ChannelError.pushBeforeJoin {
            // expected
        }
    }

    @Test
    func presenceSyncStateAndDiffMatchesPhoenixSemantics() {
        let current: Presence.State = [
            "u1": ["metas": [["phx_ref": "1"]]],
            "u2": ["metas": [["phx_ref": "2"]]],
        ]
        let incoming: Presence.State = [
            "u1": ["metas": [["phx_ref": "1"], ["phx_ref": "3"]]],
            "u3": ["metas": [["phx_ref": "4"]]],
        ]

        let synced = Presence.syncState(current, newState: incoming)
        #expect(synced["u1"] != nil)
        #expect(synced["u2"] == nil)
        #expect(synced["u3"] != nil)

        let diff: Presence.Diff = [
            "joins": ["u3": ["metas": [["phx_ref": "5"]]]],
            "leaves": ["u1": ["metas": [["phx_ref": "1"]]]],
        ]

        let afterDiff = Presence.syncDiff(synced, diff: diff)
        let u1Refs = afterDiff["u1"]?["metas"]?.compactMap { $0["phx_ref"]?.stringValue } ?? []
        let u3Refs = afterDiff["u3"]?["metas"]?.compactMap { $0["phx_ref"]?.stringValue } ?? []

        #expect(u1Refs == ["3"])
        #expect(Set(u3Refs) == Set(["4", "5"]))
    }
}
