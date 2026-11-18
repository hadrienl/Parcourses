#if DEBUG
  import Foundation

  /// Tests UI et captures du partage (#87, lot 87.4), Debug seulement : un serveur en mémoire, servi par la vraie
  /// synchro. `PARCOURSES_TEST_SHARING` choisit le scénario de la maquette (personnages : Hadrien propriétaire, Léa et
  /// Tom membres, c.martin@exemple.fr invitée) :
  /// - `owner` : Hadrien, sa liste « Courses de la semaine » partagée avec Léa (peut modifier) et Tom (lecture seule) ;
  /// - `viewer` : Tom, lecteur de cette liste ;
  /// - `invitation` : Léa, une invitation d'Hadrien en attente ;
  /// - `anonymous` : compte anonyme, une liste à soi (« Partager » passe par la connexion).
  ///
  /// `PARCOURSES_TEST_PENDING_SWITCH=1` : changement de compte interrompu (drapeau `account.switch` posé), rejoué au
  /// lancement vers le compte du scénario (#129).
  actor UITestSharingGateway: RemoteGateway {
    static let variable = "PARCOURSES_TEST_SHARING"
    static let pendingSwitchVariable = "PARCOURSES_TEST_PENDING_SWITCH"

    nonisolated enum Scenario: String {
      case owner, viewer, invitation, anonymous
    }

    static let hadrien = UUID(uuidString: "11111111-1111-4111-8111-111111111111") ?? UUID()
    static let lea = UUID(uuidString: "22222222-2222-4222-8222-222222222222") ?? UUID()
    static let tom = UUID(uuidString: "33333333-3333-4333-8333-333333333333") ?? UUID()
    static let listId = UUID(uuidString: "44444444-4444-4444-8444-444444444444") ?? UUID()
    static let invitationId = UUID(uuidString: "55555555-5555-4555-8555-555555555555") ?? UUID()
    /// Jeton du lien de test (`https://<hôte>/i/#…`, ou `parcourses://invitation#…` sans hôte).
    static let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCde"

    private let scenario: Scenario
    private let me: UUID
    private let start = Date.now.addingTimeInterval(-3600)
    private var lists: [ListRow] = []
    private var items: [UUID: ListItemRow] = [:]
    private var members: [ListMemberRow] = []
    private var invitations: [PendingInvitation] = []
    private var invitationPending: Bool
    private var signedOut = false

    /// `nil` hors scénario de partage.
    static func fromEnvironment() -> UITestSharingGateway? {
      guard let raw = ProcessInfo.processInfo.environment[variable], let scenario = Scenario(rawValue: raw) else {
        return nil
      }
      // Rien d'un lancement précédent : curseurs et nature du compte repartent de zéro.
      UserDefaultsSyncCursors().removeAll()
      UserDefaultsAccountKindStore().clear()
      if scenario != .anonymous { UserDefaultsAccountKindStore().save(.email) }
      // Ni déconnexion ni changement de compte laissés en plan par un test interrompu (#129).
      UserDefaultsAccountSignOutFlagStore().clear()
      let switchFlags = UserDefaultsAccountSwitchFlagStore()
      if ProcessInfo.processInfo.environment[pendingSwitchVariable] == "1" {
        switchFlags.save()
      } else {
        switchFlags.clear()
      }
      return UITestSharingGateway(scenario: scenario)
    }

    init(scenario: Scenario) {
      self.scenario = scenario
      switch scenario {
      case .owner, .anonymous: me = Self.hadrien
      case .viewer: me = Self.tom
      case .invitation: me = Self.lea
      }
      invitationPending = scenario == .invitation
      let created = start
      if scenario != .invitation {
        lists = [
          ListRow(
            id: Self.listId, ownerId: Self.hadrien, name: "Courses de la semaine", createdAt: created,
            updatedAt: created)
        ]
        let labels: [(String, String?, UUID, Bool)] = [
          ("Tomates", "6", Self.hadrien, false), ("Basilic", "1", Self.hadrien, false),
          ("Lait entier", "2", Self.hadrien, false), ("Beurre doux", "1", Self.lea, false),
          ("Comté", "200 g", Self.lea, true), ("Pâtes", "1", Self.hadrien, false),
        ]
        for (index, entry) in labels.enumerated() {
          let id = UUID(uuidString: String(format: "66666666-6666-4666-8666-%012d", index)) ?? UUID()
          let at = Date.now.addingTimeInterval(scenario == .anonymous ? -600 : -120 - Double(10 * (6 - index)))
          items[id] = ListItemRow(
            id: id, listId: Self.listId, productId: nil, label: entry.0, quantity: entry.1,
            checkedAt: entry.3 ? at : nil, createdAt: created,
            updatedAt: entry.2 == Self.lea ? .now.addingTimeInterval(-120) : at,
            updatedBy: scenario == .anonymous ? Self.hadrien : entry.2)
        }
      }
      if scenario == .owner || scenario == .viewer {
        members = [
          ListMemberRow(
            listId: Self.listId, userId: Self.lea, role: "editor", addedBy: Self.hadrien,
            createdAt: created.addingTimeInterval(60), updatedAt: created),
          ListMemberRow(
            listId: Self.listId, userId: Self.tom, role: "viewer", addedBy: Self.hadrien,
            createdAt: created.addingTimeInterval(120), updatedAt: created),
        ]
        invitations = [
          PendingInvitation(
            id: Self.invitationId, email: "c.martin@exemple.fr", role: .editor, createdAt: created,
            expiresAt: .now.addingTimeInterval(7 * 86_400 - 60), sentCount: 1, expired: false)
        ]
      }
    }

    private func names() -> [UUID: String] {
      [Self.hadrien: "Hadrien", Self.lea: "Léa", Self.tom: "Tom"]
    }

    // MARK: - Session

    func ensureSession(captchaToken: String?) async throws -> UUID { me }
    func currentAccountId() async throws -> UUID { me }
    func verifySession() async throws {}
    func sessionAccountId() async throws -> UUID { me }
    func acknowledgeAccount(_ id: UUID) async throws {}
    func serverDate() async throws -> Date? { .now }
    func deleteAccount() async throws { throw RemoteError.notSent }
    func signOutLocally() async throws {}
    func localSessionAccountId() async throws -> UUID? { me }
    func confirmAccountDeleted() async throws -> Bool { false }

    // MARK: - Listes et articles

    func saveList(_ list: ListUpsert) async throws {
      if let index = lists.firstIndex(where: { $0.id == list.id }) {
        let row = lists[index]
        lists[index] = ListRow(
          id: row.id, ownerId: row.ownerId, name: list.name, createdAt: row.createdAt, updatedAt: .now, updatedBy: me)
      } else {
        lists.append(
          ListRow(id: list.id, ownerId: me, name: list.name, createdAt: .now, updatedAt: .now, updatedBy: me))
      }
    }

    func deleteList(id: UUID) async throws {
      lists.removeAll { $0.id == id }
      items = items.filter { $0.value.listId != id }
    }

    func insertItem(_ item: ListItemUpsert) async throws -> Bool {
      guard items[item.id] == nil else { return false }
      guard canWrite(item.listId) else { throw RemoteError.forbidden }
      items[item.id] = ListItemRow(
        id: item.id, listId: item.listId, productId: item.productId, label: item.label, quantity: item.quantity,
        checkedAt: item.checkedAt, createdAt: .now, updatedAt: .now, updatedBy: me)
      return true
    }

    func updateItem(id: UUID, fields: ListItemFields) async throws -> Bool {
      guard let row = items[id], canWrite(row.listId) else { return false }
      let columns = Set(fields.columns)
      let values = fields.values
      items[id] = ListItemRow(
        id: id, listId: row.listId,
        productId: columns.contains(ListItemFields.productId) ? values.productId : row.productId,
        label: columns.contains(ListItemFields.label) ? values.label : row.label,
        quantity: columns.contains(ListItemFields.quantity) ? values.quantity : row.quantity,
        checkedAt: columns.contains(ListItemFields.checkedAt) ? values.checkedAt : row.checkedAt,
        createdAt: row.createdAt, updatedAt: .now, updatedBy: me)
      return true
    }

    func deleteItem(id: UUID) async throws -> Bool {
      guard let row = items[id], canWrite(row.listId) else { return false }
      items[id] = nil
      return true
    }

    private func canWrite(_ listId: UUID) -> Bool {
      lists.contains { $0.id == listId && $0.ownerId == me }
        || members.contains { $0.listId == listId && $0.userId == me && $0.role == "editor" }
    }

    private func readable() -> [ListRow] {
      lists.filter { list in list.ownerId == me || members.contains { $0.listId == list.id && $0.userId == me } }
    }

    func createVisit(_ visit: VisitInsert) async throws {}
    func insertChecks(_ checks: [CheckUpload]) async throws {}
    func closeVisit(id: UUID, endedAt: Date) async throws {}
    func visitAccess(id: UUID) async throws -> VisitAccess { .open }

    func fetchLists(updatedAfter: Date?) async throws -> [ListRow] { readable() }
    func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow] {
      let ids = Set(readable().map(\.id))
      return items.values.filter { ids.contains($0.listId) }.sorted { $0.updatedAt < $1.updatedAt }
    }
    func fetchItems(listId: UUID) async throws -> [ListItemRow] {
      try await fetchItems(updatedAfter: nil).filter { $0.listId == listId }
    }
    func fetchItemIds(listId: UUID) async throws -> [UUID] {
      try await fetchItems(listId: listId).map(\.id)
    }
    func accessibleListIds() async throws -> [UUID] { readable().map(\.id) }
    func fetchTombstones(after: Date?) async throws -> [TombstoneRow] { [] }
    func fetchTombstones(ids: [UUID]) async throws -> [TombstoneRow] { [] }
    func fetchCategories() async throws -> [CategoryRow] { [] }
    func fetchProducts() async throws -> [RemoteProduct] { [] }
    func resolveProducts(_ items: [ProductResolutionRequest]) async throws -> [ResolvedProductRow] {
      items.map { ResolvedProductRow(normalizedName: $0.name.lowercased(), id: nil, name: nil, categorySlug: nil) }
    }
    func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow] { [] }
    func searchStores(query: String, limit: Int) async throws -> [StoreSearchRow] { [] }
    func storeOrganicAisle(id: UUID) async throws -> Bool? { nil }
    func graphSnapshot(storeId: UUID, knownVersion: Int64?) async throws -> GraphSnapshotResponse { .none }

    // MARK: - Comptes

    func accountEmail() async throws -> String? {
      // Après « Se déconnecter » (#108) : la session repart anonyme.
      if signedOut { return nil }
      return switch scenario {
      case .anonymous: nil
      case .owner: "hadrien@exemple.fr"
      case .viewer: "tom@exemple.fr"
      case .invitation: "lea@exemple.fr"
      }
    }
    func linkEmail(_ email: String) async throws { throw RemoteError.network }
    func signInWithEmail(_ email: String) async throws { throw RemoteError.network }
    func verifyCode(email: String, code: String, purpose: EmailCodePurpose) async throws -> VerifiedCode {
      throw RemoteError.network
    }
    func displayName() async throws -> String? { scenario == .anonymous || signedOut ? nil : names()[me] }
    func setDisplayName(_ name: String) async throws {}
    func signOut() async throws { signedOut = true }
    func deleteAccount(accessToken: String) async throws {}

    // MARK: - Preuve d'appareil (#137)

    // Le simulateur n'a pas App Attest : `DeviceAttestation` s'arrête sur `unsupported` sans appeler ces deux-là.
    func attestationAccount() async throws -> AttestationAccount {
      AttestationAccount(id: me, isAnonymous: scenario == .anonymous || signedOut)
    }
    func attestationChallenge() async throws -> AttestationReply {
      AttestationReply(httpStatus: 200, status: "not_configured")
    }
    func verifyAttestation(challenge: String, keyId: String, attestation: String) async throws -> AttestationReply {
      AttestationReply(httpStatus: 200, status: "not_configured")
    }

    // MARK: - Partage

    func sendInvitation(listId: UUID, email: String, role: ListRole) async throws -> SentInvitation {
      if email == "lea@exemple.fr" { throw SharingRequestError(error: "already_member") }
      if email == "hadrien@exemple.fr" { throw SharingRequestError(error: "self_invitation") }
      let id = invitations.first { $0.email == email }?.id ?? UUID()
      invitations.removeAll { $0.id == id }
      invitations.insert(
        PendingInvitation(
          id: id, email: email, role: role, createdAt: .now, expiresAt: .now.addingTimeInterval(7 * 86_400),
          sentCount: 1, expired: false), at: 0)
      // Une adresse « sans-mail » simule un e-mail qui n'est pas parti.
      return SentInvitation(
        invitationId: id, link: InvitationLinks().link(token: Self.token), sent: !email.hasPrefix("sans-mail"),
        expiresAt: .now.addingTimeInterval(7 * 86_400))
    }

    func invitationLink(listId: UUID, email: String, role: ListRole) async throws -> String {
      // Comme `SupabaseGateway` : le lien de la configuration de build (`https://<hôte>/i/#…` depuis le lot 87.7).
      InvitationLinks().link(token: Self.token)
    }

    func revokeInvitation(id: UUID) async throws {
      invitations.removeAll { $0.id == id }
    }

    func listSharing(listId: UUID) async throws -> ListSharing {
      guard let list = readable().first(where: { $0.id == listId }) else { throw RemoteError.forbidden }
      let names = names()
      let rows = members.filter { $0.listId == listId }
      let role: ListRole =
        list.ownerId == me ? .owner : ListRole(rawValue: rows.first { $0.userId == me }?.role ?? "") ?? .viewer
      return ListSharing(
        listId: listId, role: role,
        owner: ListParticipant(
          userId: list.ownerId, displayName: names[list.ownerId], role: .owner, isMe: list.ownerId == me, joinedAt: nil),
        members: rows.map {
          ListParticipant(
            userId: $0.userId, displayName: names[$0.userId], role: ListRole(rawValue: $0.role) ?? .viewer,
            isMe: $0.userId == me, joinedAt: $0.createdAt)
        },
        invitations: role == .owner ? invitations : [])
    }

    func myInvitations() async throws -> [ReceivedInvitation] {
      guard scenario == .invitation, invitationPending else { return [] }
      return [
        ReceivedInvitation(
          id: Self.invitationId, listId: Self.listId, listName: "Courses de la semaine", inviterName: "Hadrien",
          role: .editor, expiresAt: .now.addingTimeInterval(6 * 86_400))
      ]
    }

    func previewInvitation(token: String) async throws -> InvitationPreview {
      guard token == Self.token else {
        return InvitationPreview(
          status: "invalid", invitationId: nil, listId: nil, listName: nil, inviterName: nil, role: nil,
          emailMatches: false, invitedEmailMasked: nil, expiresAt: nil)
      }
      // Le lien de test vise une autre adresse que celle du compte : l'avertissement de la maquette.
      return InvitationPreview(
        status: invitationPending ? "pending" : "member", invitationId: Self.invitationId, listId: nil, listName: nil,
        inviterName: "Hadrien", role: .editor, emailMatches: false, invitedEmailMasked: "c•••@exemple.fr",
        expiresAt: .now.addingTimeInterval(6 * 86_400))
    }

    func acceptInvitation(token: String) async throws -> InvitationAcceptance { join() }
    func acceptInvitation(id: UUID) async throws -> InvitationAcceptance { join() }

    private func join() -> InvitationAcceptance {
      guard invitationPending else { return InvitationAcceptance(status: "used", listId: nil, role: nil) }
      invitationPending = false
      let created = start
      lists = [
        ListRow(
          id: Self.listId, ownerId: Self.hadrien, name: "Courses de la semaine", createdAt: created, updatedAt: created)
      ]
      members = [
        ListMemberRow(
          listId: Self.listId, userId: me, role: "editor", addedBy: Self.hadrien, createdAt: .now, updatedAt: .now)
      ]
      for (index, label) in ["Tomates", "Lait entier", "Pâtes"].enumerated() {
        let id = UUID(uuidString: String(format: "77777777-7777-4777-8777-%012d", index)) ?? UUID()
        items[id] = ListItemRow(
          id: id, listId: Self.listId, productId: nil, label: label, quantity: nil, checkedAt: nil, createdAt: created,
          updatedAt: created, updatedBy: Self.hadrien)
      }
      return InvitationAcceptance(status: "accepted", listId: Self.listId, role: .editor)
    }

    func declineInvitation(id: UUID) async throws {
      invitationPending = false
    }

    func setMemberRole(listId: UUID, userId: UUID, role: ListRole) async throws {
      guard let index = members.firstIndex(where: { $0.listId == listId && $0.userId == userId }) else { return }
      let row = members[index]
      members[index] = ListMemberRow(
        listId: listId, userId: userId, role: role.rawValue, addedBy: row.addedBy, createdAt: row.createdAt,
        updatedAt: .now)
    }

    func removeMember(listId: UUID, userId: UUID) async throws {
      members.removeAll { $0.listId == listId && $0.userId == userId }
    }

    func fetchListMembers() async throws -> [ListMemberRow] {
      let ids = Set(readable().map(\.id))
      return members.filter { ids.contains($0.listId) }
    }

    func fetchProfiles() async throws -> [ProfileRow] {
      names().map { ProfileRow(userId: $0.key, displayName: $0.value, createdAt: start, updatedAt: start) }
    }
  }
#endif
