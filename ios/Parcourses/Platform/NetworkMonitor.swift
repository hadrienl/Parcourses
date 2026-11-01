import Foundation
import Network
import os

/// État du réseau (`NWPathMonitor`). Optimiste tant que le premier état n'est pas connu.
nonisolated final class NetworkMonitor: Sendable {
  private let monitor = NWPathMonitor()
  private let online = OSAllocatedUnfairLock(initialState: true)

  var isOnline: Bool { online.withLock { $0 } }

  /// Émet `true` à chaque retour du réseau. À n'écouter qu'une fois.
  func returns() -> AsyncStream<Void> {
    AsyncStream { continuation in
      monitor.pathUpdateHandler = { [online] path in
        let isOnline = path.status == .satisfied
        let wasOnline = online.withLock { state in
          defer { state = isOnline }
          return state
        }
        if isOnline && !wasOnline { continuation.yield() }
      }
      continuation.onTermination = { [monitor] _ in monitor.cancel() }
      monitor.start(queue: DispatchQueue(label: "app.parcourses.network"))
    }
  }
}
