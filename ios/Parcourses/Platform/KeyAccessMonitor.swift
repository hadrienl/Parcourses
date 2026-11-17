import Foundation
import Synchronization

/// Suit les accès au Keychain de la session (#133), même règle qu'Android (`KeyAccessMonitor`, #51). Le Keychain est
/// « bloqué » après `stuckAfterFailures` échecs de suite étalés sur au moins `stuckAfter` : plusieurs appelants qui
/// échouent ensemble pendant une même panne passagère n'y suffisent pas. Un seul accès réussi remet tout à zéro.
///
/// Propre à iOS : un échec ne compte que si les données protégées sont disponibles (appareil déverrouillé). Sinon un
/// lancement en arrière-plan avant le premier déverrouillage passerait pour un blocage.
///
/// Appelé hors du fil principal (acteur `SupabaseGateway`, SDK) : l'état est protégé par un verrou.
nonisolated final class KeyAccessMonitor: Sendable {
  /// Échecs de suite avant de tenir le Keychain pour bloqué.
  static let stuckAfterFailures = 3
  /// Durée minimale de la série d'échecs : un Keychain lent au démarrage ne suffit pas.
  static let stuckAfter = Duration.seconds(30)

  private nonisolated struct State {
    var failures = 0
    var firstFailureAt: ContinuousClock.Instant?
    var isStuck = false
  }

  private let state = Mutex(State())
  private let isProtectedDataAvailable: @Sendable () -> Bool
  private let now: @Sendable () -> ContinuousClock.Instant

  /// `now` : horloge monotone, remplacée dans les tests.
  init(
    isProtectedDataAvailable: @escaping @Sendable () -> Bool = { true },
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.isProtectedDataAvailable = isProtectedDataAvailable
    self.now = now
  }

  /// Le Keychain refuse tout depuis assez longtemps : la session ne se relira pas.
  var isStuck: Bool { state.withLock { $0.isStuck } }

  /// Issue d'un accès au Keychain.
  func record(success: Bool) {
    if success {
      state.withLock { $0 = State() }
      return
    }
    // Appareil verrouillé : l'échec est attendu, il ne dit rien d'un blocage.
    guard isProtectedDataAvailable() else { return }
    let at = now()
    state.withLock { state in
      if state.failures == 0 { state.firstFailureAt = at }
      state.failures += 1
      if state.failures >= Self.stuckAfterFailures, let first = state.firstFailureAt,
        first.duration(to: at) >= Self.stuckAfter
      {
        state.isStuck = true
      }
    }
  }
}
