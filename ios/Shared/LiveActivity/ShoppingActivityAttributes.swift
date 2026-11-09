import ActivityKit
import Foundation

/// Live Activity du mode courses (#9 §10). Partagée par l'app, qui la pilote, et l'extension, qui l'affiche.
/// Mise à jour en local seulement : pas de push APNs au MVP.
nonisolated struct ShoppingActivityAttributes: ActivityAttributes, Equatable {
  /// État qui change pendant la visite.
  nonisolated struct ContentState: Codable, Hashable {
    /// Articles encore à prendre.
    var remaining: Int
    /// Articles de la visite : à prendre et déjà cochés (les introuvables n'y comptent pas).
    var total: Int
    /// Prochain article à prendre, dans l'ordre affiché.
    var nextItemLabel: String?
    /// Rayon de ce prochain article.
    var nextCategoryLabel: String?
    /// Visite terminée : l'activité n'affiche plus qu'un message de fin.
    var isFinished: Bool
    /// Articles à prendre dans l'ordre affiché, le prochain en tête (`maxPendingItems` au plus). L'état est autonome,
    /// comme celui de la Live Update Android : app tuée, « Cocher le suivant » retrouve l'ordre affiché sans
    /// recalculer le tri.
    var pendingItemIds: [UUID]

    init(
      remaining: Int, total: Int, nextItemLabel: String? = nil, nextCategoryLabel: String? = nil,
      isFinished: Bool = false, pendingItemIds: [UUID] = []
    ) {
      self.remaining = remaining
      self.total = total
      self.nextItemLabel = nextItemLabel
      self.nextCategoryLabel = nextCategoryLabel
      self.isFinished = isFinished
      self.pendingItemIds = pendingItemIds
    }

    /// Tolérant : une activité écrite par une autre version de l'app reste lisible, champ manquant ou non.
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      remaining = try container.decodeIfPresent(Int.self, forKey: .remaining) ?? 0
      total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
      nextItemLabel = try container.decodeIfPresent(String.self, forKey: .nextItemLabel)
      nextCategoryLabel = try container.decodeIfPresent(String.self, forKey: .nextCategoryLabel)
      isFinished = try container.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
      pendingItemIds = try container.decodeIfPresent([UUID].self, forKey: .pendingItemIds) ?? []
    }

    /// ActivityKit plafonne l'état à 4 Ko : 30 identifiants en prennent à peine 1,2.
    static let maxPendingItems = 30

    /// Prochain article à prendre : celui que coche « Cocher le suivant ».
    var nextItemId: UUID? { pendingItemIds.first }

    /// Part déjà prise, entre 0 et 1.
    var progress: Double {
      total > 0 ? Double(total - remaining) / Double(total) : 0
    }
  }

  /// Visite suivie ; `nil` sans magasin choisi. Une activité n'est reprise qu'à la même visite.
  var visitId: UUID?
  var listName: String
  var storeName: String?
}
