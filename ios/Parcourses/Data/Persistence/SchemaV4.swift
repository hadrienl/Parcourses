import Foundation
import SwiftData

/// Synchro multi-appareil (#87, lot 87.3) : `ShoppingList.ownerId`, `ListItem.isOnServer`, `ListItem.updatedBy` et
/// `OutboxEntry.changedFields`. Les autres modèles sont repris tels quels. Limité aux API iOS 18.
nonisolated enum SchemaV4: VersionedSchema {
  static let versionIdentifier = Schema.Version(4, 0, 0)

  static var models: [any PersistentModel.Type] {
    [
      ShoppingList.self, ListItem.self, SchemaV1.Visit.self, SchemaV1.Check.self, SchemaV2.Store.self,
      SchemaV1.GraphSnapshot.self, SchemaV1.Product.self, SchemaV1.Category.self, SchemaV1.CategorySeedState.self,
      OutboxEntry.self,
    ]
  }

  /// Liste de courses (`lists`).
  @Model
  nonisolated final class ShoppingList {
    #Unique<ShoppingList>([\.id])

    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    /// Suppression douce, le temps que le `DELETE` parte au serveur.
    var deletedAt: Date?
    /// Stocké en texte : un `#Predicate` sur un enum échoue sur iOS 18 (`unsupportedPredicate`).
    var syncStateRaw: String
    /// Propriétaire, posé par le serveur et appris à la descente. `nil` tant que la liste n'est pas descendue : elle
    /// est alors à soi (vecteur `008`).
    var ownerId: UUID?

    @Transient var syncState: SyncState {
      get { SyncState(rawValue: syncStateRaw) ?? .pending }
      set { syncStateRaw = newValue.rawValue }
    }

    init(
      id: UUID = UUID(), name: String, createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil,
      syncState: SyncState = .pending, ownerId: UUID? = nil
    ) {
      self.id = id
      self.name = name
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.deletedAt = deletedAt
      self.syncStateRaw = syncState.rawValue
      self.ownerId = ownerId
    }
  }

  /// Article d'une liste (`list_items`). `categoryId`, `notFoundAt` et `position` restent locaux.
  @Model
  nonisolated final class ListItem {
    #Unique<ListItem>([\.id])
    #Index<ListItem>([\.listId])

    var id: UUID
    var listId: UUID
    var label: String
    var normalizedName: String
    /// Texte libre, comme la colonne `quantity` du serveur.
    var quantity: String?
    var productId: UUID?
    var categoryId: String
    var checkedAt: Date?
    var notFoundAt: Date?
    var position: Int
    var updatedAt: Date
    /// Stocké en texte : un `#Predicate` sur un enum échoue sur iOS 18 (`unsupportedPredicate`).
    var syncStateRaw: String
    /// Vrai dès qu'un envoi est accusé ou que la ligne est descendue : l'envoi suivant ne porte que les champs
    /// modifiés (vecteur `001`).
    var isOnServer: Bool = false
    /// Dernier compte à avoir écrit la ligne, posé par le serveur.
    var updatedBy: UUID?

    @Transient var syncState: SyncState {
      get { SyncState(rawValue: syncStateRaw) ?? .pending }
      set { syncStateRaw = newValue.rawValue }
    }

    init(
      id: UUID = UUID(), listId: UUID, label: String, normalizedName: String, quantity: String? = nil,
      productId: UUID? = nil, categoryId: String, checkedAt: Date? = nil, notFoundAt: Date? = nil, position: Int,
      updatedAt: Date = .now, syncState: SyncState = .pending, isOnServer: Bool = false, updatedBy: UUID? = nil
    ) {
      self.id = id
      self.listId = listId
      self.label = label
      self.normalizedName = normalizedName
      self.quantity = quantity
      self.productId = productId
      self.categoryId = categoryId
      self.checkedAt = checkedAt
      self.notFoundAt = notFoundAt
      self.position = position
      self.updatedAt = updatedAt
      self.syncStateRaw = syncState.rawValue
      self.isOnServer = isOnServer
      self.updatedBy = updatedBy
    }
  }

  /// Entrée de la file d'envoi, locale.
  @Model
  nonisolated final class OutboxEntry {
    #Unique<OutboxEntry>([\.id])
    #Index<OutboxEntry>([\.nextAttemptAt], [\.sequence], [\.entityId])

    var id: UUID
    /// Ordre de traitement, alloué par `ModelContext.enqueueOutboxEntry` : `createdAt` ne le garantit pas.
    var sequence: Int64
    /// Stocké en texte, comme `syncStateRaw`.
    var kindRaw: String
    var entityId: UUID
    var payload: Data
    var createdAt: Date
    var attempts: Int
    var nextAttemptAt: Date
    var lastError: String?
    /// `failed` : erreur définitive, l'entrée n'est plus rejouée (#9 §5.3).
    var syncStateRaw: String
    /// Première erreur serveur d'une suite ininterrompue. Persistant : un relancement ne remet pas le délai à zéro.
    var serverFailingSince: Date?
    /// `upsertItem` : colonnes serveur modifiées, triées. `nil` pour les autres entrées, et pour une entrée d'article
    /// écrite avant 87.3 : on ne sait pas ce qui a changé, toute la ligne part (`ListItemFields.all`).
    var changedFields: [String]?

    /// `nil` si le type stocké est inconnu de cette version de l'app.
    @Transient var kind: OutboxKind? {
      OutboxKind(rawValue: kindRaw)
    }

    @Transient var syncState: SyncState {
      get { SyncState(rawValue: syncStateRaw) ?? .pending }
      set { syncStateRaw = newValue.rawValue }
    }

    init(
      id: UUID = UUID(), sequence: Int64, kind: OutboxKind, entityId: UUID, payload: Data, createdAt: Date = .now,
      attempts: Int = 0, nextAttemptAt: Date = .now, lastError: String? = nil, syncState: SyncState = .pending,
      serverFailingSince: Date? = nil, changedFields: [String]? = nil
    ) {
      self.id = id
      self.sequence = sequence
      self.kindRaw = kind.rawValue
      self.entityId = entityId
      self.payload = payload
      self.createdAt = createdAt
      self.attempts = attempts
      self.nextAttemptAt = nextAttemptAt
      self.lastError = lastError
      self.syncStateRaw = syncState.rawValue
      self.serverFailingSince = serverFailingSince
      self.changedFields = changedFields
    }
  }

  /// Après la migration légère : un article déjà accusé (`synced`) est sur le serveur. Un article en attente reste à
  /// `false` ; son entrée, écrite avant 87.3, n'a pas de `changedFields` et part en entier (mise à jour, puis insertion
  /// si 0 ligne), comme avant.
  static func markItemsOnServer(in context: ModelContext) throws {
    let synced = SyncState.synced.rawValue
    for item in try context.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.syncStateRaw == synced })) {
      item.isOnServer = true
    }
    try context.save()
  }
}
