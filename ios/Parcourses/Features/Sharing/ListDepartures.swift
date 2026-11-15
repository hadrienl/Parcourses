import Foundation

/// Listes quittées volontairement sur cet appareil (« Quitter la liste », #87 §1.4) : l'écran Liste revient alors à Mes
/// listes, au lieu d'annoncer « n'est plus partagée avec vous », réservé à un retrait décidé par le propriétaire.
/// Un départ ne sert qu'une fois : consommé par l'écran Liste, ou oublié dès que la liste revient sur l'appareil
/// (réinvitation). Un retrait plus tard par le propriétaire s'annonce donc bien comme un retrait.
final class ListDepartures {
  private var left: Set<UUID> = []

  func record(_ listId: UUID) {
    left.insert(listId)
  }

  /// Vrai si la liste a été quittée ici ; le départ est alors retiré.
  func consume(_ listId: UUID) -> Bool {
    left.remove(listId) != nil
  }

  /// La liste est (de nouveau) sur l'appareil : un départ noté plus tôt ne vaut plus.
  func forget(_ listId: UUID) {
    left.remove(listId)
  }
}
