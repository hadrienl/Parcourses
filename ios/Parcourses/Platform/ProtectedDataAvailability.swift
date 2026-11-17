import Synchronization
import UIKit

/// Données protégées disponibles (appareil déverrouillé), lisible depuis n'importe quel fil : `KeyAccessMonitor` est
/// appelé hors du fil principal, où `UIApplication` n'est pas accessible.
nonisolated final class ProtectedDataAvailability: Sendable {
  private let available: Mutex<Bool>

  init(isAvailable: Bool) {
    available = Mutex(isAvailable)
  }

  var isAvailable: Bool { available.withLock { $0 } }

  func update(_ isAvailable: Bool) {
    available.withLock { $0 = isAvailable }
  }

  /// État du système, tenu à jour par les notifications de l'app. Une seule instance par processus : ses
  /// observateurs ne sont jamais retirés.
  @MainActor static func live(center: NotificationCenter = .default) -> ProtectedDataAvailability {
    let state = ProtectedDataAvailability(isAvailable: UIApplication.shared.isProtectedDataAvailable)
    _ = center.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil
    ) { _ in state.update(true) }
    _ = center.addObserver(
      forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil
    ) { _ in state.update(false) }
    // Assurance : relu à chaque retour au premier plan, au cas où une notification aurait manqué.
    _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { state.update(UIApplication.shared.isProtectedDataAvailable) }
    }
    return state
  }
}
