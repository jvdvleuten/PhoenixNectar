import Foundation

/// Opaque handle for a scheduled action, used for cancellation.
struct PhoenixSchedulerToken: Hashable, Sendable {
  fileprivate let id = UUID()
}

/// Scheduling abstraction used by socket, channel, and push time-based behavior.
protocol PhoenixScheduler {
  @discardableResult
  func scheduleOnce(
    after delay: Duration,
    tolerance: Duration?,
    _ action: @escaping @Sendable () async -> Void
  ) -> PhoenixSchedulerToken

  @discardableResult
  func scheduleRepeating(
    every interval: Duration,
    tolerance: Duration?,
    _ action: @escaping @Sendable () async -> Void
  ) -> PhoenixSchedulerToken

  func cancel(_ token: PhoenixSchedulerToken?)
  func cancelAll()
}

final class ClockScheduler: PhoenixScheduler, @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [PhoenixSchedulerToken: Task<Void, Never>] = [:]
  private let clock = ContinuousClock()

  init() {}

  @discardableResult
  func scheduleOnce(
    after delay: Duration,
    tolerance: Duration? = nil,
    _ action: @escaping @Sendable () async -> Void
  ) -> PhoenixSchedulerToken {
    let token = PhoenixSchedulerToken()
    let deadline = clock.now.advanced(by: delay)
    let clock = self.clock

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
    }

    lock.lock()
    tasks[token] = task
    lock.unlock()

    return token
  }

  @discardableResult
  func scheduleRepeating(
    every interval: Duration,
    tolerance: Duration? = nil,
    _ action: @escaping @Sendable () async -> Void
  ) -> PhoenixSchedulerToken {
    let token = PhoenixSchedulerToken()
    let clock = self.clock

    let task = Task {
      var next = clock.now.advanced(by: interval)

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
        next = next.advanced(by: interval)
      }
    }

    lock.lock()
    tasks[token] = task
    lock.unlock()

    return token
  }

  func cancel(_ token: PhoenixSchedulerToken?) {
    guard let token else { return }
    lock.lock()
    let task = tasks.removeValue(forKey: token)
    lock.unlock()
    task?.cancel()
  }

  func cancelAll() {
    lock.lock()
    let snapshot = tasks
    tasks.removeAll()
    lock.unlock()
    snapshot.values.forEach { $0.cancel() }
  }
}
