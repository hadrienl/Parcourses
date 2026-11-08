import ActivityKit
import Foundation

/// Live Activity du mode courses (#9 §10). Partagée par l'app, qui la pilote, et l'extension, qui l'affiche.
/// Mise à jour en local seulement : pas de push APNs au MVP.
nonisolated struct ShoppingActivityAttributes: ActivityAttributes {
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
    var isFinished = false

    /// Part déjà prise, entre 0 et 1.
    var progress: Double {
      total > 0 ? Double(total - remaining) / Double(total) : 0
    }
  }

  var listName: String
  var storeName: String?
}
