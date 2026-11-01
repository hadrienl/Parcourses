import Foundation
import SwiftData

/// Ajoute `OutboxEntry.serverFailingSince`. Les autres modèles sont repris tels quels.
nonisolated enum SchemaV3: VersionedSchema {
  static let versionIdentifier = Schema.Version(3, 0, 0)

  static var models: [any PersistentModel.Type] {
    [
      SchemaV1.ShoppingList.self, SchemaV1.ListItem.self, SchemaV1.Visit.self, SchemaV1.Check.self,
      SchemaV2.Store.self, SchemaV1.GraphSnapshot.self, SchemaV1.Product.self, SchemaV1.Category.self,
      SchemaV1.CategorySeedState.self, OutboxEntry.self,
    ]
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
      serverFailingSince: Date? = nil
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
    }
  }
}
