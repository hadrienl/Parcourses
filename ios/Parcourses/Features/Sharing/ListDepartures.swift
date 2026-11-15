import Foundation

/// Listes quittées volontairement sur cet appareil (« Quitter la liste », #87 §1.4) : l'écran Liste revient alors à Mes
/// listes, au lieu d'annoncer « n'est plus partagée avec vous », réservé à un retrait décidé par le propriétaire.
final class ListDepartures {
  private var left: Set<UUID> = []

  func record(_ listId: UUID) {
    left.insert(listId)
  }

  func contains(_ listId: UUID) -> Bool {
    left.contains(listId)
  }
}
