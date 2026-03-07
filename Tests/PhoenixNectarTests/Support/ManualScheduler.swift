import Foundation
@testable import PhoenixNectar

@MainActor
final class ManualScheduler: PhoenixScheduler {
  enum Entry {
    case once(action: @MainActor @Sendable () async -> Void)
    case repeating(action: @MainActor @Sendable () async -> Void)
  }

  private var entries: [PhoenixSchedulerToken: Entry] = [:]

  @discardableResult
  func scheduleOnce(
    after interval: TimeInterval,
    tolerance: Duration?,
    _ action: @escaping @MainActor @Sendable () async -> Void
  ) -> PhoenixSchedulerToken {
    let token = PhoenixSchedulerToken()
    entries[token] = .once(action: action)
    return token
  }

  @discardableResult
  func scheduleRepeating(
    every interval: TimeInterval,
    tolerance: Duration?,
    _ action: @escaping @MainActor @Sendable () async -> Void
  ) -> PhoenixSchedulerToken {
    let token = PhoenixSchedulerToken()
    entries[token] = .repeating(action: action)
    return token
  }

  func cancel(_ token: PhoenixSchedulerToken?) {
    guard let token else { return }
    entries[token] = nil
  }

  func cancelAll() {
    entries.removeAll()
  }

  func fireAll() async {
    let snapshot = entries
    for (token, entry) in snapshot {
      switch entry {
      case .once(let action):
        entries[token] = nil
        await action()
      case .repeating(let action):
        await action()
      }
    }
  }
}
