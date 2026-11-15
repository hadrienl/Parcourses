import Foundation
import SwiftData

/// Réparation des rôles au lancement (#87, lot 87.4). La migration V4→V5 pose `owner` sur toutes les listes : une liste
/// d'un autre compte déjà descendue (invitation acceptée sur un autre appareil du même compte) proposerait alors
/// Renommer, Supprimer et Partager jusqu'à la descente suivante. Elle passe en lecture seule ; la descente pose ensuite
/// son vrai rôle, sans message (`applyMemberships`, liste sans participants lus).
enum ListRoleRepair {
  /// Listes réparées. Sans compte connu, rien ne change : une liste sans compte est à soi.
  @discardableResult
  static func apply(in context: ModelContext, me: UUID?) throws -> Int {
    guard let me else { return 0 }
    let owner = ListRole.owner.rawValue
    let suspects = try context.fetch(
      FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.roleRaw == owner && $0.ownerId != nil }))
    let foreign = suspects.filter { $0.ownerId != me && $0.participantsData == nil }
    guard !foreign.isEmpty else { return 0 }
    for list in foreign { list.role = .viewer }
    try context.save()
    return foreign.count
  }
}
