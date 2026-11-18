import Foundation

/// Erreur distante classée pour la file d'envoi (9.7, contrat hors ligne de `docs/data-model.md`).
nonisolated enum RemoteError: Error, Sendable, Equatable {
  /// Pas de réseau ou requête interrompue.
  case network
  /// Session absente ou expirée.
  case unauthorized
  /// Code `42501` uniquement : refus RLS ou privilège. Un 403 sans code n'en est pas un (`server`).
  case forbidden
  /// `23514` et `23505` : renvoyer la même ligne ne changerait rien.
  case constraint(code: String)
  /// `23503` : la ligne parente n'est pas encore arrivée. Réessai à plafonner (9.7).
  case dependencyMissing(code: String)
  /// Requête invalide, définitive.
  case rejected(code: String)
  /// Erreur côté serveur ou passerelle.
  case server(code: String)
  /// Réponse illisible, sans code ni statut exploitable. Réessayable : on ne sait pas si la ligne est passée.
  case unexpected
  /// La session appartient à un autre compte que le dernier connu : les lignes existantes ne sont plus
  /// visibles, et un enregistrement « réussirait » sans rien écrire. `SyncEngine` réidentifie alors les données.
  case accountChanged
  /// Catégorie absente de la table serveur, même après relecture. Jamais abandonnée : le serveur peut être en
  /// retard sur `shared/categories/`, et la coche ne doit pas être perdue.
  case unknownCategory(String)
  /// Keychain verrouillé (arrière-plan avant le premier déverrouillage) : la session existe peut-être encore.
  case keychainLocked
  /// Suppression du compte seulement : GoTrue répond que le compte ou sa session n'existent plus
  /// (`user_not_found`, `refresh_token_not_found`, `session_not_found`). Seule preuve d'une suppression faite.
  case accountGone(code: String)
  /// Suppression du compte seulement : la requête n'a pas quitté l'appareil (pas de réseau, hôte introuvable).
  case notSent

  /// PostgREST ne trouve pas la fonction appelée : serveur en retard d'une migration. Reste `rejected`, la file
  /// n'en dépend pas ; seule la résolution des produits la réessaie plus tôt (`SyncRetryPolicy.resolutionDelay`).
  static let functionNotFoundCode = "PGRST202"

  /// `true` si l'élément doit rester dans la file.
  var isRetryable: Bool {
    switch self {
    case .network, .unauthorized, .dependencyMissing, .server, .unexpected, .accountChanged, .unknownCategory,
      .keychainLocked, .accountGone, .notSent:
      true
    case .forbidden, .constraint, .rejected:
      false
    }
  }

  /// 4xx sans code : ni réessai sans fin, ni abandon immédiat. 403, 408 et 429 restent passagers.
  var isCappedClientFailure: Bool {
    guard case .server(let code) = self, let status = Int(code) else { return false }
    return (400..<500).contains(status) && ![403, 408, 429].contains(status)
  }

  /// Classe un code renvoyé par PostgREST (SQLSTATE ou `PGRSTxxx`).
  static func fromPostgrest(code: String?) -> RemoteError {
    guard let code else { return .unexpected }
    if code == "42501" { return .forbidden }
    if code == "23514" || code == "23505" { return .constraint(code: code) }
    if code == "23503" { return .dependencyMissing(code: code) }
    if ["PGRST301", "PGRST302", "PGRST303"].contains(code) { return .unauthorized }
    // PGRST0xx : base injoignable ou saturée, et PGRST5xx : erreur interne.
    if code.hasPrefix("PGRST0") || code.hasPrefix("PGRST5") { return .server(code: code) }
    // Autres PGRST : requête mal formée ; 22, 23, 42, P0 : données ou SQL refusés.
    if ["PGRST", "22", "23", "42", "P0"].contains(where: code.hasPrefix) { return .rejected(code: code) }
    return .server(code: code)
  }

  /// Classe un statut HTTP pour les réponses sans code PostgREST. Un 403 de passerelle reste réessayable :
  /// le traiter comme un refus RLS ferait disparaître une coche jamais reçue.
  static func fromHTTP(status: Int) -> RemoteError {
    status == 401 ? .unauthorized : .server(code: String(status))
  }

  /// Erreur d'une réponse en échec dont le corps ne porte pas de `code` : son statut se perdrait ensuite.
  /// `nil` si la réponse a réussi ou si le code PostgREST suffit.
  static func uncodedFailure(status: Int, body: Data) -> RemoteError? {
    guard status >= 400 else { return nil }
    let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    return json?["code"] is String ? nil : fromHTTP(status: status)
  }
}

/// Correspondance entre les identifiants partagés (`shared/categories/`, slug serveur) et l'`Int16` serveur,
/// qui ne doit jamais être écrit en dur ni sortir du gateway.
nonisolated struct CategoryMap: Sendable, Equatable {
  /// Délai avant de relire la table pour un slug qu'elle ne connaissait pas.
  static let missingSlugLifetime: TimeInterval = 3600

  private let idsBySlug: [String: Int16]
  private let slugsById: [Int16: String]
  /// Cache négatif : sans lui, chaque coche d'un slug inconnu relirait la table.
  private(set) var missingSlugs: [String: Date]

  init(rows: [CategoryRow], missingSlugs: [String: Date] = [:]) {
    self.missingSlugs = missingSlugs
    idsBySlug = Dictionary(rows.map { ($0.slug, $0.id) }) { first, _ in first }
    slugsById = Dictionary(rows.map { ($0.id, $0.slug) }) { first, _ in first }
  }

  func remoteId(forSlug slug: String) -> Int16? { idsBySlug[slug] }

  func shouldReload(forSlug slug: String, now: Date) -> Bool {
    guard idsBySlug[slug] == nil else { return false }
    guard let date = missingSlugs[slug] else { return true }
    return now.timeIntervalSince(date) >= Self.missingSlugLifetime
  }

  mutating func markMissing(_ slug: String, at date: Date) {
    missingSlugs[slug] = date
  }

  func slug(forRemoteId id: Int16) -> String? { slugsById[id] }
}

/// Une visite telle que le compte courant la voit.
nonisolated enum VisitAccess: Sendable, Equatable {
  case open
  case closed
  /// Absente ou appartenant à un autre compte : la RLS ne permet pas de distinguer.
  case notVisible
}

/// Code reçu par e-mail : liaison d'une adresse au compte anonyme (`verifyOtp` de type `email_change`, même compte) ou
/// connexion à un compte existant (type `email`). Mêmes noms sur Android.
nonisolated enum EmailCodePurpose: String, Sendable {
  case link
  case signIn
}

/// Code vérifié : le compte de la session, et le jeton d'accès du compte anonyme quitté s'il y en a un.
nonisolated struct VerifiedCode: Sendable, Equatable {
  let accountId: UUID
  /// Connexion vers un autre compte depuis un compte anonyme : son jeton d'accès (valable une heure), gardé pour le
  /// supprimer après la reprise (`deleteAccount(accessToken:)`). `nil` sinon.
  let previousAnonymousToken: String?
}

/// Refus de GoTrue sur une demande de code ou sa vérification : statut HTTP et `error_code`, tels que les vecteurs
/// `010` les décrivent. Le réseau reste `RemoteError.network`.
nonisolated struct AuthRequestError: Error, Sendable, Equatable {
  let status: Int
  let code: String?
}

/// Accès distant de l'app. `SupabaseGateway` en est l'implémentation ; les tests fournissent une doublure.
/// Toutes les écritures sont idempotentes : la file peut les rejouer. Elles lèvent `RemoteError`.
nonisolated protocol RemoteGateway: Sendable {
  /// Renvoie l'utilisateur courant, et crée un compte anonyme s'il n'y a pas de session. Pendant une suppression de
  /// compte (drapeau `account.deletion`), n'en crée jamais : `unauthorized` sans session.
  @discardableResult
  func ensureSession(captchaToken: String?) async throws -> UUID

  /// Compte de la session existante, sans jamais en créer : `unauthorized` s'il n'y en a pas.
  func currentAccountId() async throws -> UUID
  /// Interroge le serveur : `unauthorized` si la session n'y est plus valable (compte supprimé ailleurs).
  func verifySession() async throws
  /// Compte de la session, même différent du dernier connu. Jamais de création : `unauthorized` sans session,
  /// `keychainLocked` si le Keychain est verrouillé.
  func sessionAccountId() async throws -> UUID
  /// Les données locales ont été réidentifiées pour `id` : il devient le dernier compte connu.
  func acknowledgeAccount(_ id: UUID) async throws
  /// Heure du serveur (en-tête HTTP `Date`), `nil` si la réponse n'en porte pas de lisible.
  func serverDate() async throws -> Date?

  /// Supprime le compte de la session et toutes ses données serveur (RPC `delete_my_account`, #68). Rafraîchit
  /// d'abord la session : le jeton obtenu permet de rejouer l'appel, idempotent, si la réponse se perd. Ne crée
  /// jamais de compte. Après succès, la session est refusée : `verifySession` lève `unauthorized`.
  func deleteAccount() async throws
  /// Oublie la session dans le SDK, sans appel au serveur : elle n'y existe plus.
  func signOutLocally() async throws
  /// Compte de la session enregistrée sur l'appareil, sans appel au serveur : `nil` s'il n'y en a pas.
  /// `keychainLocked` si le Keychain ne peut pas le dire.
  func localSessionAccountId() async throws -> UUID?
  /// Suppression du compte : le serveur prouve-t-il que le compte de la session n'existe plus ? `true` sur
  /// `user_not_found`, `refresh_token_not_found` ou `session_not_found` ; `false` si le compte répond. Tout le reste
  /// lève : le doute demeure. Sans comparaison au dernier compte connu.
  func confirmAccountDeleted() async throws -> Bool

  func saveList(_ list: ListUpsert) async throws
  func deleteList(id: UUID) async throws
  /// Insertion complète, idempotente (`on conflict do nothing`) : un article jamais accusé. Vrai si une ligne a été
  /// insérée ; faux si elle existait déjà (réponse d'une insertion précédente perdue) ou si l'article est enterré
  /// (pierre tombale, 87.1). L'appelant envoie alors les champs modifiés par une mise à jour.
  @discardableResult
  func insertItem(_ item: ListItemUpsert) async throws -> Bool
  /// Mise à jour des seules colonnes de `fields`, sans repli sur l'insertion. Vrai si une ligne a été touchée : 0 ligne
  /// veut dire supprimé ailleurs ou accès perdu, la RLS filtre sans erreur (vecteur `003`).
  @discardableResult
  func updateItem(id: UUID, fields: ListItemFields) async throws -> Bool
  /// Vrai si une ligne a été supprimée.
  @discardableResult
  func deleteItem(id: UUID) async throws -> Bool

  func createVisit(_ visit: VisitInsert) async throws
  func insertChecks(_ checks: [CheckUpload]) async throws
  func closeVisit(id: UUID, endedAt: Date) async throws
  /// Ce que la RLS laisse voir d'une visite : distingue une coche tardive d'une visite d'un autre compte.
  func visitAccess(id: UUID) async throws -> VisitAccess

  /// `updatedAfter` a un recouvrement de quelques secondes : l'appelant doit fusionner de façon idempotente.
  func fetchLists(updatedAfter: Date?) async throws -> [ListRow]
  func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow]
  /// Articles d'une liste, sans curseur : liste nouvellement accessible ou rechargée (`refreshAccess`).
  func fetchItems(listId: UUID) async throws -> [ListItemRow]
  /// Identifiants des articles d'une liste : réconciliation complète des suppressions (vecteur `007`).
  func fetchItemIds(listId: UUID) async throws -> [UUID]
  /// Listes lisibles par le compte (RPC `accessible_list_ids`, vecteur `005`).
  func accessibleListIds() async throws -> [UUID]
  /// Pierres tombales depuis `after` (avec le recouvrement du curseur), toutes si `nil`.
  func fetchTombstones(after: Date?) async throws -> [TombstoneRow]
  /// Pierres tombales de ces articles : lève le doute après une mise à jour sans ligne.
  func fetchTombstones(ids: [UUID]) async throws -> [TombstoneRow]
  func fetchCategories() async throws -> [CategoryRow]
  func fetchProducts() async throws -> [RemoteProduct]
  /// Produits publiés depuis `publishedSince` (#47, avec recouvrement), tous si `nil`.
  func fetchProducts(publishedSince: Date?) async throws -> [RemoteProduct]

  /// Produits partagés des libellés saisis librement (RPC `resolve_products`), créés au besoin par le serveur.
  /// Au plus `SyncRetryPolicy.maxResolutionBatch` entrées ; une ligne par entrée, dans l'ordre.
  func resolveProducts(_ items: [ProductResolutionRequest]) async throws -> [ResolvedProductRow]

  /// La position n'est ni conservée ni journalisée ici.
  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow]

  /// Repli sans position (refus de localisation) : RPC `search_stores`, par nom ou adresse.
  func searchStores(query: String, limit: Int) async throws -> [StoreSearchRow]

  /// Rayon bio d'un magasin connu par son identifiant. `nil` si le serveur ne le connaît pas.
  func storeOrganicAisle(id: UUID) async throws -> Bool?

  /// Instantané du graphe d'un magasin, s'il diffère de `knownVersion`. Exige une session, jamais créée ici.
  func graphSnapshot(storeId: UUID, knownVersion: Int64?) async throws -> GraphSnapshotResponse

  // MARK: Comptes e-mail (#87)

  /// Adresse du compte de la session, sans appel au serveur. `nil` pour un compte anonyme ou sans session.
  func accountEmail() async throws -> String?
  /// Lie `email` au compte anonyme de la session (créé s'il manque) : un code de type `email_change` part. Lève
  /// `AuthRequestError` (`422 email_exists` : adresse déjà prise, vecteur `010`).
  func linkEmail(_ email: String) async throws
  /// Demande un code de connexion à un compte existant, sans jamais en créer (`shouldCreateUser: false`).
  func signInWithEmail(_ email: String) async throws
  /// Vérifie le code. La session devient celle du compte de l'adresse. Lève `AuthRequestError` (code faux ou expiré).
  func verifyCode(email: String, code: String, purpose: EmailCodePurpose) async throws -> VerifiedCode
  /// Prénom du compte (`profiles`), `nil` s'il n'en a pas.
  func displayName() async throws -> String?
  /// Écrit le prénom du compte e-mail de la session.
  func setDisplayName(_ name: String) async throws
  /// Déconnexion : la session est oubliée sur l'appareil, puis révoquée sur le serveur si le réseau le permet.
  func signOut() async throws
  /// Supprime l'ancien compte anonyme avec son jeton gardé en mémoire, après une reprise vers un compte existant.
  /// Jamais le compte de la session.
  func deleteAccount(accessToken: String) async throws

  // MARK: Partage (#87, lot 87.4)

  // Réseau exigé, rien en file. Les refus du serveur lèvent `SharingRequestError` (son `error` est l'entrée du
  // vecteur `003`, `nil` sans réponse) ; `listSharing` lève `RemoteError.forbidden` sur une liste illisible.

  /// Crée l'invitation (ou renouvelle son jeton) et l'envoie par e-mail : Edge Function `send-invitation`.
  func sendInvitation(listId: UUID, email: String, role: ListRole) async throws -> SentInvitation
  /// « Copier le lien » : `create_invitation` sans e-mail, nouveau jeton (l'ancien lien ne marche plus). Renvoie le
  /// lien construit par `InvitationLinks`.
  func invitationLink(listId: UUID, email: String, role: ListRole) async throws -> String
  func revokeInvitation(id: UUID) async throws
  func listSharing(listId: UUID) async throws -> ListSharing
  func myInvitations() async throws -> [ReceivedInvitation]
  func previewInvitation(token: String) async throws -> InvitationPreview
  func acceptInvitation(token: String) async throws -> InvitationAcceptance
  func acceptInvitation(id: UUID) async throws -> InvitationAcceptance
  func declineInvitation(id: UUID) async throws
  func setMemberRole(listId: UUID, userId: UUID, role: ListRole) async throws
  /// Retire un membre (propriétaire), ou quitte la liste (son propre `userId`).
  func removeMember(listId: UUID, userId: UUID) async throws
  /// Membres des listes lisibles (`list_members`), pour les rôles et les pastilles relus à la descente.
  func fetchListMembers() async throws -> [ListMemberRow]
  /// Prénoms lisibles : le mien et ceux des autres membres de mes listes (`profiles`).
  func fetchProfiles() async throws -> [ProfileRow]
}

/// Réponse de `accept_invitation` : son statut, la liste rejointe pour l'ouvrir, et mon rôle.
nonisolated struct InvitationAcceptance: Sendable, Equatable {
  /// `accepted`, `member`, `invalid`, `expired`, `used`, `rate_limited`.
  let status: String
  let listId: UUID?
  let role: ListRole?

  /// Suite donnée dans l'app (vecteur `005`).
  var outcome: AcceptOutcome { SharingDecisions.acceptOutcome(status: status) }
}

/// Événement du canal temps réel d'un compte.
nonisolated enum RealtimeEvent: Sendable, Equatable {
  /// Canal rejoint, ou rejoint à nouveau après une coupure : les signaux manqués ne sont pas rejoués.
  case subscribed
  case signal(RealtimeSignal)
}

/// Canal privé `user:<uid>` (#87 §6.2). `SupabaseGateway` l'implémente avec le Realtime de `supabase-swift`.
nonisolated protocol RealtimeTransport: Sendable {
  /// Rejoint le canal du compte et en livre les événements, jusqu'à `closeUserSignals()` ou l'annulation.
  func userSignals(userId: UUID) async -> AsyncStream<RealtimeEvent>
  /// Quitte le canal et ferme la connexion.
  func closeUserSignals() async
}

nonisolated extension RemoteGateway {
  /// Par défaut (doublures de test) : le catalogue entier, filtré sur l'appareil.
  func fetchProducts(publishedSince: Date?) async throws -> [RemoteProduct] {
    let rows = try await fetchProducts()
    guard let publishedSince else { return rows }
    return rows.filter { ($0.publishedAt ?? .distantPast) >= publishedSince }
  }
}
