import Foundation
import SwiftData

/// État d'envoi d'une entité synchronisée (#9 §4.1).
nonisolated enum SyncState: String, Codable, Sendable {
  case pending
  case synced
  case failed
}

/// Nature d'une entrée de la file d'envoi (#9 §5.1).
nonisolated enum OutboxKind: String, Codable, Sendable {
  case upsertList
  case deleteList
  case upsertItem
  case deleteItem
  case createVisit
  case insertChecks
  case closeVisit
}

/// Première version du schéma local, limitée aux API iOS 18 (ni héritage, ni type iOS 26+).
///
/// Les noms sont repris par Android : toute modification passe par une nouvelle version et par `SYNC.md`.
/// Les modèles sont `nonisolated` pour que le futur `@ModelActor` de synchronisation (9.7) puisse les manipuler.
nonisolated enum SchemaV1: VersionedSchema {
  static let versionIdentifier = Schema.Version(1, 0, 0)

  static var models: [any PersistentModel.Type] {
    [
      ShoppingList.self, ListItem.self, Visit.self, Check.self, Store.self,
      GraphSnapshot.self, Product.self, Category.self, CategorySeedState.self, OutboxEntry.self,
    ]
  }

  /// Liste de courses (`lists`). `owner_id` est posé par le serveur.
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

    @Transient var syncState: SyncState {
      get { SyncState(rawValue: syncStateRaw) ?? .pending }
      set { syncStateRaw = newValue.rawValue }
    }

    init(
      id: UUID = UUID(), name: String, createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil,
      syncState: SyncState = .pending
    ) {
      self.id = id
      self.name = name
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.deletedAt = deletedAt
      self.syncStateRaw = syncState.rawValue
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

    @Transient var syncState: SyncState {
      get { SyncState(rawValue: syncStateRaw) ?? .pending }
      set { syncStateRaw = newValue.rawValue }
    }

    init(
      id: UUID = UUID(), listId: UUID, label: String, normalizedName: String, quantity: String? = nil,
      productId: UUID? = nil, categoryId: String, checkedAt: Date? = nil, notFoundAt: Date? = nil, position: Int,
      updatedAt: Date = .now, syncState: SyncState = .pending
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
    }
  }

  /// Visite d'un magasin (`visits`). Création et clôture partent séparément.
  @Model
  nonisolated final class Visit {
    #Unique<Visit>([\.id])

    var id: UUID
    var storeId: UUID
    var listId: UUID
    var listWasSorted: Bool
    var startedAt: Date
    var endedAt: Date?
    /// Stocké en texte : un `#Predicate` sur un enum échoue sur iOS 18 (`unsupportedPredicate`).
    var syncStateRaw: String
    var endSyncStateRaw: String

    @Transient var syncState: SyncState {
      get { SyncState(rawValue: syncStateRaw) ?? .pending }
      set { syncStateRaw = newValue.rawValue }
    }

    @Transient var endSyncState: SyncState {
      get { SyncState(rawValue: endSyncStateRaw) ?? .pending }
      set { endSyncStateRaw = newValue.rawValue }
    }

    init(
      id: UUID = UUID(), storeId: UUID, listId: UUID, listWasSorted: Bool, startedAt: Date = .now,
      endedAt: Date? = nil, syncState: SyncState = .pending, endSyncState: SyncState = .pending
    ) {
      self.id = id
      self.storeId = storeId
      self.listId = listId
      self.listWasSorted = listWasSorted
      self.startedAt = startedAt
      self.endedAt = endedAt
      self.syncStateRaw = syncState.rawValue
      self.endSyncStateRaw = endSyncState.rawValue
    }
  }

  /// Coche horodatée (`checks`), immuable. `itemId` ne part pas au serveur.
  @Model
  nonisolated final class Check {
    #Unique<Check>([\.id])
    #Index<Check>([\.visitId])

    var id: UUID
    var visitId: UUID
    var itemId: UUID
    /// `productId` xor `categoryId` : garanti par `CheckSubject` à l'écriture.
    var productId: UUID?
    var categoryId: String?
    var checkedAt: Date
    /// Stocké en texte : un `#Predicate` sur un enum échoue sur iOS 18 (`unsupportedPredicate`).
    var syncStateRaw: String

    @Transient var syncState: SyncState {
      get { SyncState(rawValue: syncStateRaw) ?? .pending }
      set { syncStateRaw = newValue.rawValue }
    }

    init(
      id: UUID = UUID(), visitId: UUID, itemId: UUID, productId: UUID?, categoryId: String?, checkedAt: Date = .now,
      syncState: SyncState = .pending
    ) {
      self.id = id
      self.visitId = visitId
      self.itemId = itemId
      self.productId = productId
      self.categoryId = categoryId
      self.checkedAt = checkedAt
      self.syncStateRaw = syncState.rawValue
    }
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

    init(
      id: UUID, name: String, chain: String? = nil, address: String? = nil, lastDistanceM: Double? = nil,
      lastUsedAt: Date? = nil
    ) {
      self.id = id
      self.name = name
      self.chain = chain
      self.address = address
      self.lastDistanceM = lastDistanceM
      self.lastUsedAt = lastUsedAt
    }
  }

  /// Instantané du graphe d'un magasin, JSON brut remplacé d'un bloc (#9 §4.3).
  @Model
  nonisolated final class GraphSnapshot {
    #Unique<GraphSnapshot>([\.storeId])

    var storeId: UUID
    var snapshotVersion: Int64
    var paramsVersion: Int64
    var confidenceQ: Int64
    var fetchedAt: Date
    var payload: Data

    init(
      storeId: UUID, snapshotVersion: Int64, paramsVersion: Int64, confidenceQ: Int64, fetchedAt: Date = .now,
      payload: Data
    ) {
      self.storeId = storeId
      self.snapshotVersion = snapshotVersion
      self.paramsVersion = paramsVersion
      self.confidenceQ = confidenceQ
      self.fetchedAt = fetchedAt
      self.payload = payload
    }
  }

  /// Produit du catalogue en cache (`products`).
  @Model
  nonisolated final class Product {
    #Unique<Product>([\.id])

    var id: UUID
    var name: String
    var normalizedName: String
    /// Peut manquer : la colonne serveur `category_id` est nullable.
    var categoryId: String?

    init(id: UUID, name: String, normalizedName: String, categoryId: String? = nil) {
      self.id = id
      self.name = name
      self.normalizedName = normalizedName
      self.categoryId = categoryId
    }
  }

  /// Catégorie de rayon en cache. `id` est l'identifiant stable de `Domain`, référencé par `ListItem.categoryId`.
  @Model
  nonisolated final class Category {
    #Unique<Category>([\.id])

    var id: String
    var slug: String
    var rank: Int
    var label: String
    /// Identifiant serveur, apparié par slug. `nil` tant que le serveur ne connaît pas ce slug.
    var remoteId: Int16?

    init(id: String, slug: String, rank: Int, label: String, remoteId: Int16? = nil) {
      self.id = id
      self.slug = slug
      self.rank = rank
      self.label = label
      self.remoteId = remoteId
    }
  }

  /// Version de `categories.json` déjà appliquée au store, écrite dans le même `save()` que les catégories.
  @Model
  nonisolated final class CategorySeedState {
    #Unique<CategorySeedState>([\.id])

    /// Ligne unique.
    static let singletonId = "categories"

    var id: String
    var version: Int

    init(id: String = CategorySeedState.singletonId, version: Int) {
      self.id = id
      self.version = version
    }
  }

  /// Entrée de la file d'envoi, locale. Le traitement arrive en 9.7.
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
      attempts: Int = 0, nextAttemptAt: Date = .now, lastError: String? = nil, syncState: SyncState = .pending
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
    }
  }
}

// Noms courts vers la version courante : le reste de l'app ne cite jamais SchemaV1.
typealias ShoppingList = SchemaV1.ShoppingList
typealias ListItem = SchemaV1.ListItem
typealias Visit = SchemaV1.Visit
typealias Check = SchemaV1.Check
typealias Store = SchemaV2.Store
typealias GraphSnapshot = SchemaV1.GraphSnapshot
typealias Product = SchemaV1.Product
typealias Category = SchemaV1.Category
typealias CategorySeedState = SchemaV1.CategorySeedState
typealias OutboxEntry = SchemaV1.OutboxEntry
