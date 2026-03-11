import PhoenixNectar

func observeConnectionState(client: Socket) async {
  let stream = await client.connectionStateStream()

  Task {
    for await state in stream {
      switch state {
      case .idle:
        print("idle")
      case .connecting:
        print("connecting")
      case .connected:
        print("connected")
      case .reconnecting(let attempt, let delay):
        print("reconnecting attempt:", attempt, "delay:", delay)
      case .disconnected(let code, let reason):
        print("disconnected:", code, reason ?? "")
      case .failed(let error):
        print("failed:", error.localizedDescription)
      }
    }
  }
}
