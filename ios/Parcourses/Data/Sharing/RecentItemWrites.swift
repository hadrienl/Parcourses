import Foundation
import os

/// Écho de mes propres écritures (#87 §6.6) : le serveur prévient aussi l'auteur d'un changement. Un signal `items`
/// reçu peu après un envoi réussi sur la même liste vient très probablement de moi : il est ignoré, sinon chaque coche du
/// mode courses déclencherait une descente de plus. Rien ne change côté serveur.
nonisolated final class RecentItemWrites: Sendable {
  /// Fenêtre de l'écho : le signal arrive en quelques centaines de millisecondes après la réponse.
  static let echoWindow: TimeInterval = 2

  private let sent = OSAllocatedUnfairLock<[UUID: Date]>(initialState: [:])

  /// Envoi d'un article accepté par le serveur, sur cette liste.
  func record(listId: UUID, at date: Date = .now) {
    sent.withLock { $0[listId] = date }
  }

  /// Signal `items` de cette liste reçu dans les 2 s qui suivent un envoi réussi : l'écho de mon écriture.
  func isEcho(_ signal: RealtimeSignal, at date: Date = .now) -> Bool {
    guard signal.kind == "items", let listId = signal.listId else { return false }
    return sent.withLock { sent in
      guard let last = sent[listId] else { return false }
      let elapsed = date.timeIntervalSince(last)
      return elapsed >= 0 && elapsed < Self.echoWindow
    }
  }
}
