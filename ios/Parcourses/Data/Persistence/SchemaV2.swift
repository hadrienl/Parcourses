import Foundation
import SwiftData

/// Ajoute `Store.organicAisle` (#28). Les autres modèles sont repris tels quels de `SchemaV1`.
nonisolated enum SchemaV2: VersionedSchema {
  static let versionIdentifier = Schema.Version(2, 0, 0)

  static var models: [any PersistentModel.Type] {
    [
      SchemaV1.ShoppingList.self, SchemaV1.ListItem.self, SchemaV1.Visit.self, SchemaV1.Check.self, Store.self,
      SchemaV1.GraphSnapshot.self, SchemaV1.Product.self, SchemaV1.Category.self, SchemaV1.CategorySeedState.self,
      SchemaV1.OutboxEntry.self,
    ]
  }

  /// Magasin en cache. Aucune position n'est stockée, ni du magasin ni de l'utilisateur.
  @Model
  nonisolated final class Store {
    #Unique<Store>([\.id])

    var id: UUID
    var name: String
    var chain: String?
    var address: String?
    /// Jamais écrit : avec le magasin et `lastUsedAt`, une distance situerait l'utilisateur. Toujours `nil`.
    var lastDistanceM: Double?
    var lastUsedAt: Date?
    /// Le magasin a un rayon bio. Faux tant que le serveur n'a rien dit.
    var organicAisle: Bool = false

    init(
      id: UUID, name: String, chain: String? = nil, address: String? = nil, lastDistanceM: Double? = nil,
      lastUsedAt: Date? = nil, organicAisle: Bool = false
    ) {
      self.id = id
      self.name = name
      self.chain = chain
      self.address = address
      self.lastDistanceM = lastDistanceM
      self.lastUsedAt = lastUsedAt
      self.organicAisle = organicAisle
    }
  }
}
