import Foundation
import SwiftData

/// Partage d'une liste (#87, lot 87.4) : `ShoppingList.role`, durable, et `ShoppingList.participantsData` (propriétaire
/// et membres, pour les pastilles et les marques d'auteur hors ligne). Les autres modèles sont repris tels quels.
/// Limité aux API iOS 18 ; migration légère depuis V4 (valeurs par défaut).
nonisolated enum SchemaV5: VersionedSchema {
  static let versionIdentifier = Schema.Version(5, 0, 0)

  static var models: [any PersistentModel.Type] {
    [
      ShoppingList.self, SchemaV4.ListItem.self, SchemaV1.Visit.self, SchemaV1.Check.self, SchemaV2.Store.self,
      SchemaV1.GraphSnapshot.self, SchemaV1.Product.self, SchemaV1.Category.self, SchemaV1.CategorySeedState.self,
      SchemaV4.OutboxEntry.self,
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
    /// Mon rôle (`ListRole`, en texte) : `owner` pour une liste créée sur l'appareil, sinon relu à la descente et par
    /// `refreshAccess`. Une liste d'avant 87.4 est à soi : seule une liste partagée avec moi a un autre rôle.
    var roleRaw: String = ListRole.owner.rawValue
    /// Propriétaire et membres (`[ListParticipant]` en JSON), `nil` tant que la descente ne les a pas lus.
    var participantsData: Data?

    @Transient var syncState: SyncState {
      get { SyncState(rawValue: syncStateRaw) ?? .pending }
      set { syncStateRaw = newValue.rawValue }
    }

    /// Rôle illisible (version future) : lecteur, le plus prudent.
    @Transient var role: ListRole {
      get { ListRole(rawValue: roleRaw) ?? .viewer }
      set { roleRaw = newValue.rawValue }
    }

    @Transient var participants: [ListParticipant] {
      get { participantsData.flatMap { try? JSONDecoder().decode([ListParticipant].self, from: $0) } ?? [] }
      set { participantsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// Partagée : au moins un autre participant que moi.
    @Transient var isShared: Bool { participants.contains { !$0.isMe } }

    init(
      id: UUID = UUID(), name: String, createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil,
      syncState: SyncState = .pending, ownerId: UUID? = nil, role: ListRole = .owner,
      participants: [ListParticipant] = []
    ) {
      self.id = id
      self.name = name
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.deletedAt = deletedAt
      self.syncStateRaw = syncState.rawValue
      self.ownerId = ownerId
      self.roleRaw = role.rawValue
      self.participantsData = participants.isEmpty ? nil : try? JSONEncoder().encode(participants)
    }
  }
}
