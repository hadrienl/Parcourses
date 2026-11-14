import Foundation

/// Requête d'envoi d'un article (vecteur `001`).
nonisolated enum ItemSaveRequest: Sendable, Equatable {
  /// Jamais arrivé au serveur : insertion complète, idempotente.
  case insert
  /// Déjà sur le serveur : mise à jour des seules colonnes modifiées (noms serveur, triés).
  case patch(fields: [String])
  /// Rien à envoyer.
  case none
}

/// Mise à jour ou suppression qui a touché 0 ligne (vecteur `003`).
nonisolated enum ZeroRowOutcome: String, Sendable {
  /// Pierre tombale présente : l'article et son entrée partent, sans nouvel essai.
  case deletedElsewhere
  /// Pas de pierre tombale : accès perdu ou rôle abaissé, `SyncEngine.refreshAccess(listId:)`.
  case accessLost
}

/// Insertion d'un article refusée en `42501` (vecteur `004`).
nonisolated enum InsertRefusedOutcome: String, Sendable {
  /// Liste pas encore partie : l'article l'attend, sans essai consommé.
  case waitForList
  /// Liste d'un autre propriétaire : rôle à relire, liste à recharger.
  case refreshAccess
  /// Liste à soi, déjà synchronisée : refus abandonné, puis réconciliation des listes à la descente.
  case reconcile
}

/// Liste locale vue par la réconciliation (vecteur `005`).
nonisolated struct LocalListState: Sendable, Equatable {
  let id: UUID
  /// Déjà arrivée au serveur au moins une fois (accusée ou descendue).
  let syncedOnce: Bool
}

/// Réconciliation des listes (vecteur `005`). Identifiants triés.
nonisolated struct ListReconciliation: Sendable, Equatable {
  /// Listes déjà synchronisées absentes du serveur : retirées de l'appareil avec leurs articles et leur file.
  let remove: [UUID]
  /// Listes accessibles inconnues de l'appareil : descente complète, sans curseur.
  let fetchFully: [UUID]
}

/// Mode de descente des suppressions d'articles (vecteur `007`).
nonisolated enum TombstonePullMode: String, Sendable {
  case incremental
  case fullReconcile
}

/// Liste locale vue par `AccountRekey` (vecteur `008`).
nonisolated struct RekeyListState: Sendable, Equatable {
  /// `nil` : jamais descendue, donc à soi.
  let ownerId: UUID?
  let deleted: Bool
  let itemCount: Int
  let createdAt: Date
  let updatedAt: Date
}

/// Sort d'une liste à la reprise de compte (vecteur `008`).
nonisolated enum RekeyPlan: String, Sendable {
  /// Renvoyée au nouveau compte sous de nouveaux identifiants.
  case resend
  /// Liste d'autrui : retirée de l'appareil, jamais renvoyée.
  case drop
  /// Supprimée localement : sa suppression s'achève.
  case remove
  /// Vide et jamais modifiée : retirée sans être renvoyée.
  case skip
}

/// Session perdue (vecteur `009`).
nonisolated enum SessionLossAction: String, Sendable {
  case createAnonymous
  case waitForSignIn
}

/// Étape qui suit `linkEmail` (vecteur `010`).
nonisolated enum LinkEmailNextStep: String, Sendable {
  case enterLinkCode
  case signInExisting
  case rateLimited
  case retry
}

/// Décisions de synchro, fonctions pures communes à iOS et Android (`shared/test-vectors/sync/`, référence
/// `shared/reference/sync.ts`). Mêmes noms et mêmes sorties sur les deux plateformes.
nonisolated enum SyncDecisions {
  /// Les pierres tombales sont purgées à 30 jours : au-delà de 29, la descente incrémentale pourrait en manquer.
  static let tombstoneSafeDays = 29

  static func itemSaveRequest(isOnServer: Bool, changedFields: [String]) -> ItemSaveRequest {
    guard isOnServer else { return .insert }
    let fields = uniqueSorted(changedFields)
    return fields.isEmpty ? .none : .patch(fields: fields)
  }

  /// `pending` : champs de l'entrée remplacée, `nil` s'il n'y en avait pas.
  static func mergeChangedFields(pending: [String]?, new: [String]) -> [String] {
    uniqueSorted((pending ?? []) + new)
  }

  static func zeroRowOutcome(tombstoned: Bool) -> ZeroRowOutcome {
    tombstoned ? .deletedElsewhere : .accessLost
  }

  static func insertRefusedOutcome(listSynced: Bool, listOwnedByMe: Bool) -> InsertRefusedOutcome {
    guard listSynced else { return .waitForList }
    return listOwnedByMe ? .reconcile : .refreshAccess
  }

  static func reconcileLists(local: [LocalListState], accessible: [UUID]) -> ListReconciliation {
    let reachable = Set(accessible)
    let known = Set(local.map(\.id))
    return ListReconciliation(
      remove: sorted(local.filter { $0.syncedOnce && !reachable.contains($0.id) }.map(\.id)),
      fetchFully: sorted(accessible.filter { !known.contains($0) }))
  }

  static func applyTombstones(localItems: [UUID], tombstones: [UUID]) -> [UUID] {
    let local = Set(localItems)
    return sorted(tombstones.filter(local.contains))
  }

  static func tombstonePullMode(cursor: Date?, now: Date) -> TombstonePullMode {
    guard let cursor else { return .fullReconcile }
    let limit = TimeInterval(tombstoneSafeDays) * 86_400
    return now.timeIntervalSince(cursor) > limit ? .fullReconcile : .incremental
  }

  static func rekeyPlan(previousAccountId: UUID, list: RekeyListState) -> RekeyPlan {
    if let owner = list.ownerId, owner != previousAccountId { return .drop }
    if list.deleted { return .remove }
    if list.itemCount == 0, list.updatedAt == list.createdAt { return .skip }
    return .resend
  }

  static func sessionLossAction(accountKind: AccountKind) -> SessionLossAction {
    accountKind == .email ? .waitForSignIn : .createAnonymous
  }

  static func linkEmailNextStep(status: Int, errorCode: String?) -> LinkEmailNextStep {
    if (200..<300).contains(status) { return .enterLinkCode }
    if status == 422, errorCode == "email_exists" { return .signInExisting }
    if status == 429 { return .rateLimited }
    return .retry
  }

  private static func uniqueSorted(_ values: [String]) -> [String] {
    Array(Set(values)).sorted()
  }

  /// UUID en minuscules, comme les vecteurs : l'ordre est celui du texte.
  private static func sorted(_ ids: [UUID]) -> [UUID] {
    Array(Set(ids)).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
  }
}
