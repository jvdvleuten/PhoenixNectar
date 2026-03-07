import Foundation

struct PendingFrame: Sendable {
  let topic: String
  let event: String
  let payload: Payload
  let ref: String?
  let joinRef: String?
}

actor SocketRuntime {
  private var pendingHeartbeatRef: String?
  private var reconnectAttempts: Int = 0
  private var sendBuffer: [PendingFrame] = []

  func clearPendingHeartbeat() {
    pendingHeartbeatRef = nil
  }

  func markPendingHeartbeat(_ ref: String) {
    pendingHeartbeatRef = ref
  }

  func hasPendingHeartbeat() -> Bool {
    pendingHeartbeatRef != nil
  }

  func acknowledgeHeartbeat(ref: String) {
    if pendingHeartbeatRef == ref {
      pendingHeartbeatRef = nil
    }
  }

  func resetReconnectAttempts() {
    reconnectAttempts = 0
  }

  func nextReconnectAttempt() -> Int {
    reconnectAttempts += 1
    return reconnectAttempts
  }

  func enqueueBufferedFrame(_ frame: PendingFrame) {
    sendBuffer.append(frame)
  }

  func removeBufferedFrame(ref: String) {
    sendBuffer.removeAll { $0.ref == ref }
  }

  func drainBufferedFrames() -> [PendingFrame] {
    let drained = sendBuffer
    sendBuffer.removeAll()
    return drained
  }
}
