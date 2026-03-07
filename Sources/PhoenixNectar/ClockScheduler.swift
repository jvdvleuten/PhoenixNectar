import Foundation

/// Opaque handle for a scheduled action, used for cancellation.
public struct PhoenixSchedulerToken: Hashable, Sendable {
  fileprivate let id = UUID()
}

/// Scheduling abstraction used by socket, channel, and push time-based behavior.
public protocol PhoenixScheduler {
  @discardableResult
  func scheduleOnce(
    after interval: TimeInterval,
    tolerance: Duration?,
    _ action: @escaping @Sendable () async -> Void
  ) -> PhoenixSchedulerToken

  @discardableResult
  func scheduleRepeating(
    every interval: TimeInterval,
    tolerance: Duration?,
    _ action: @escaping @Sendable () async -> Void
  ) -> PhoenixSchedulerToken

  func cancel(_ token: PhoenixSchedulerToken?)
  func cancelAll()
}

final class ClockScheduler: PhoenixScheduler {
  private actor State {
    var tasks: [PhoenixSchedulerToken: Task<Void, Never>] = [:]

    func insert(_ token: PhoenixSchedulerToken, task: Task<Void, Never>) {
      tasks[token] = task
    }

    func cancel(_ token: PhoenixSchedulerToken) {
      tasks[token]?.cancel()
      tasks[token] = nil
    }

    func cancelAll() {
      tasks.values.forEach { $0.cancel() }
      tasks.removeAll()
    }

    func remove(_ token: PhoenixSchedulerToken) {
      tasks[token] = nil
    }
  }

  private let state = State()
  private let clock = ContinuousClock()

  @discardableResult
  func scheduleOnce(
    after interval: TimeInterval,
    tolerance: Duration? = nil,
    _ action: @escaping @Sendable () async -> Void
  ) -> PhoenixSchedulerToken {
    let token = PhoenixSchedulerToken()
    let deadline = clock.now.advanced(by: .seconds(interval))
    let clock = self.clock
    let state = self.state

    let task = Task {
      do {
        if let tolerance {
          try await Task.sleep(until: deadline, tolerance: tolerance, clock: clock)
        } else {
          try await Task.sleep(until: deadline, clock: clock)
        }
      } catch {
        return
      }

      guard !Task.isCancelled else { return }
      await action()
      await state.remove(token)
    }
    Task { await state.insert(token, task: task) }

    return token
  }

  @discardableResult
  func scheduleRepeating(
    every interval: TimeInterval,
    tolerance: Duration? = nil,
    _ action: @escaping @Sendable () async -> Void
  ) -> PhoenixSchedulerToken {
    let token = PhoenixSchedulerToken()
    let stride = Duration.seconds(interval)
    let clock = self.clock
    let state = self.state

    let task = Task {
      var next = clock.now.advanced(by: stride)

      while !Task.isCancelled {
        do {
          if let tolerance {
            try await Task.sleep(until: next, tolerance: tolerance, clock: clock)
          } else {
            try await Task.sleep(until: next, clock: clock)
          }
        } catch {
          return
        }

        guard !Task.isCancelled else { return }
        await action()
        next = next.advanced(by: stride)
      }

      await state.remove(token)
    }
    Task { await state.insert(token, task: task) }

    return token
  }

  func cancel(_ token: PhoenixSchedulerToken?) {
    guard let token else { return }
    let state = self.state
    Task { await state.cancel(token) }
  }

  func cancelAll() {
    let state = self.state
    Task { await state.cancelAll() }
  }
}
