import Foundation

/// Opaque handle for a scheduled action, used for cancellation.
public struct PhoenixSchedulerToken: Hashable, Sendable {
  fileprivate let id = UUID()
}

/// Scheduling abstraction used by socket, channel, and push time-based behavior.
@MainActor
public protocol PhoenixScheduler {
  @discardableResult
  func scheduleOnce(
    after interval: TimeInterval,
    tolerance: Duration?,
    _ action: @escaping @MainActor @Sendable () async -> Void
  ) -> PhoenixSchedulerToken

  @discardableResult
  func scheduleRepeating(
    every interval: TimeInterval,
    tolerance: Duration?,
    _ action: @escaping @MainActor @Sendable () async -> Void
  ) -> PhoenixSchedulerToken

  func cancel(_ token: PhoenixSchedulerToken?)
  func cancelAll()
}

@MainActor
final class ClockScheduler: PhoenixScheduler {
  private var tasks: [PhoenixSchedulerToken: Task<Void, Never>] = [:]
  private let clock = ContinuousClock()

  @discardableResult
  func scheduleOnce(
    after interval: TimeInterval,
    tolerance: Duration? = nil,
    _ action: @escaping @MainActor @Sendable () async -> Void
  ) -> PhoenixSchedulerToken {
    let token = PhoenixSchedulerToken()
    let deadline = clock.now.advanced(by: .seconds(interval))
    let clock = self.clock

    tasks[token] = Task { [weak self] in
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
      self?.remove(token)
    }

    return token
  }

  @discardableResult
  func scheduleRepeating(
    every interval: TimeInterval,
    tolerance: Duration? = nil,
    _ action: @escaping @MainActor @Sendable () async -> Void
  ) -> PhoenixSchedulerToken {
    let token = PhoenixSchedulerToken()
    let stride = Duration.seconds(interval)

    tasks[token] = Task { [weak self] in
      guard let self else { return }
      var next = self.clock.now.advanced(by: stride)

      while !Task.isCancelled {
        do {
          if let tolerance {
            try await Task.sleep(until: next, tolerance: tolerance, clock: self.clock)
          } else {
            try await Task.sleep(until: next, clock: self.clock)
          }
        } catch {
          return
        }

        guard !Task.isCancelled else { return }
        await action()
        next = next.advanced(by: stride)
      }

      self.remove(token)
    }

    return token
  }

  func cancel(_ token: PhoenixSchedulerToken?) {
    guard let token else { return }
    tasks[token]?.cancel()
    tasks[token] = nil
  }

  func cancelAll() {
    tasks.values.forEach { $0.cancel() }
    tasks.removeAll()
  }

  private func remove(_ token: PhoenixSchedulerToken) {
    tasks[token] = nil
  }
}
