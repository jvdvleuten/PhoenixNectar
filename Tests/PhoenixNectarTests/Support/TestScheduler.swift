import Foundation
@testable import PhoenixNectar

final class TestScheduler: PhoenixScheduler, @unchecked Sendable {
  private struct State {
    var once: [PhoenixSchedulerToken: @Sendable () async -> Void] = [:]
    var repeating: [PhoenixSchedulerToken: @Sendable () async -> Void] = [:]
  }

  private let lock = NSLock()
  private var state = State()

  @discardableResult
  func scheduleOnce(
    after delay: Duration,
    tolerance: Duration?,
    _ action: @escaping @Sendable () async -> Void
  ) -> PhoenixSchedulerToken {
    let token = PhoenixSchedulerToken()
    lock.lock()
    state.once[token] = action
    lock.unlock()
    return token
  }

  @discardableResult
  func scheduleRepeating(
    every interval: Duration,
    tolerance: Duration?,
    _ action: @escaping @Sendable () async -> Void
  ) -> PhoenixSchedulerToken {
    let token = PhoenixSchedulerToken()
    lock.lock()
    state.repeating[token] = action
    lock.unlock()
    return token
  }

  func cancel(_ token: PhoenixSchedulerToken?) {
    guard let token else { return }
    lock.lock()
    state.once[token] = nil
    state.repeating[token] = nil
    lock.unlock()
  }

  func cancelAll() {
    lock.lock()
    state.once.removeAll()
    state.repeating.removeAll()
    lock.unlock()
  }

  var hasPendingOnce: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !state.once.isEmpty
  }

  var hasPendingRepeating: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !state.repeating.isEmpty
  }

  func fireScheduled() async {
    let actions = drainAllActions()
    for action in actions {
      await action()
    }
  }

  func fireOnceScheduled() async {
    let actions = drainOnceActions()
    for action in actions {
      await action()
    }
  }

  private func drainAllActions() -> [@Sendable () async -> Void] {
    let actions: [@Sendable () async -> Void]
    lock.lock()
    actions = Array(state.once.values) + Array(state.repeating.values)
    state.once.removeAll()
    lock.unlock()
    return actions
  }

  private func drainOnceActions() -> [@Sendable () async -> Void] {
    let actions: [@Sendable () async -> Void]
    lock.lock()
    actions = Array(state.once.values)
    state.once.removeAll()
    lock.unlock()
    return actions
  }
}
