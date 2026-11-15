import Domain
import Foundation
import Supabase
import SwiftData
import Testing

@testable import Parcourses

private nonisolated let t0 = syncEpoch
private let hadrien = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let lea = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let tom = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

/// Attend qu'une condition devienne vraie (tâches de fond, 2 s au plus).
@MainActor
private func eventually(_ condition: () async -> Bool) async {
  for _ in 0..<200 {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(10))
  }
}

/// Changements d'accès annoncés par la synchro, pour une liste.
@MainActor
private final class AccessChangeRecorder {
  private(set) var changes: [SharingAccessChange] = []
  private var token: (any NSObjectProtocol)?

  init(listId: UUID) {
    // Postés sur le fil principal par la synchro (`queue` nil : livrés aussitôt, sur ce fil).
    token = NotificationCenter.default.addObserver(forName: .sharingAccessDidChange, object: nil, queue: nil) {
      [weak self] notification in
      guard let change = notification.object as? SharingAccessChange, change.listId == listId else { return }
      MainActor.assumeIsolated { self?.changes.append(change) }
    }
  }

  func stop() {
    if let token { NotificationCenter.default.removeObserver(token) }
    token = nil
  }
}

// MARK: - Décisions et valeurs

@MainActor
struct SharingValueTests {
  private func member(_ list: UUID, _ user: UUID, _ role: String, at offset: TimeInterval) -> ListMemberRow {
    ListMemberRow(
      listId: list, userId: user, role: role, createdAt: t0.addingTimeInterval(offset), updatedAt: t0)
  }

  @Test func membershipsGiveMyRoleAndTheParticipantsInOrder() {
    let list = UUID()
    let rows = [
      member(list, tom, "viewer", at: 20), member(list, lea, "editor", at: 10), member(UUID(), lea, "editor", at: 0),
    ]
    let names = [hadrien: "Hadrien", lea: "Léa", tom: "Tom"]
    let asLea = ListMemberships.resolve(listId: list, ownerId: hadrien, me: lea, members: rows, names: names)
    #expect(asLea.role == .editor)
    #expect(asLea.participants.map(\.displayName) == ["Hadrien", "Léa", "Tom"])
    #expect(asLea.participants.map(\.isMe) == [false, true, false])
    let asOwner = ListMemberships.resolve(listId: list, ownerId: hadrien, me: hadrien, members: rows, names: names)
    #expect(asOwner.role == .owner)
    // Plus membre : pas de rôle, la réconciliation retirera la liste.
    let stranger = ListMemberships.resolve(listId: list, ownerId: hadrien, me: UUID(), members: rows, names: names)
    #expect(stranger.role == nil)
    // Sans membre : liste non partagée.
    let alone = ListMemberships.resolve(listId: UUID(), ownerId: hadrien, me: hadrien, members: rows, names: names)
    #expect(alone.participants.isEmpty && alone.role == .owner)
  }

  @Test func roleChangesThatDeserveAMessage() {
    #expect(ListMemberships.change(from: .editor, to: .viewer) == .downgraded(droppedChanges: 0))
    #expect(ListMemberships.change(from: .viewer, to: .editor) == .upgraded)
    #expect(ListMemberships.change(from: .owner, to: .owner) == nil)
    #expect(ListMemberships.change(from: .editor, to: .owner) == nil)
  }

  @Test func pillsShowOthersWithTwoLettersForTwinInitialsAndAnOverflow() {
    #expect(ListAccess.pillLabels(names: ["Léa", "Tom"]) == ["L", "T"])
    #expect(ListAccess.pillLabels(names: ["Léa", "Laure", "Tom"]) == ["Lé", "La", "T"])
    #expect(ListAccess.pillLabels(names: ["Ana", "Bea", "Cyd", "Dan", "Eve"]) == ["A", "B", "C", "+2"])
    #expect(ListAccess.pillLabels(names: [nil]) == ["?"])
  }

  @Test func membersButtonAndAuthorMarks() {
    let participants = [
      ListParticipant(userId: hadrien, displayName: "Hadrien", role: .owner, isMe: true, joinedAt: nil),
      ListParticipant(userId: lea, displayName: "Léa", role: .editor, isMe: false, joinedAt: t0),
      ListParticipant(userId: tom, displayName: "Tom", role: .viewer, isMe: false, joinedAt: t0),
    ]
    let owner = ListAccess(role: .owner, participants: participants, me: hadrien)
    #expect(owner.membersButtonLabel == "Membres : Léa, Tom et vous. Partager la liste")
    #expect(owner.pillLabels == ["L", "T"])
    #expect(owner.authorMark(updatedBy: lea) == "L")
    #expect(owner.authorMark(updatedBy: hadrien) == nil)
    #expect(owner.otherName(lea) == "Léa")
    let viewer = ListAccess(
      role: .viewer,
      participants: participants.map {
        ListParticipant(
          userId: $0.userId, displayName: $0.displayName, role: $0.role, isMe: $0.userId == tom, joinedAt: nil)
      }, me: tom)
    #expect(viewer.membersButtonLabel == "Membres : Hadrien, Léa et vous. Voir les membres")
    #expect(viewer.isReadOnly && viewer.ownerName == "Hadrien")
    #expect(!ListAccess().isShared && ListAccess().authorMark(updatedBy: lea) == nil)
  }

  @Test func invitationLinksUseTheSchemeUntilAHostIsConfigured() throws {
    let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCde"
    let scheme = InvitationLinks(httpsHost: "  ")
    #expect(scheme.httpsHost == nil)
    #expect(scheme.link(token: token) == "parcourses://invitation#\(token)")
    let schemeURL = try #require(URL(string: "parcourses://invitation#\(token)"))
    let httpsURL = try #require(URL(string: "https://parcourses.example/i/#\(token)"))
    #expect(scheme.token(in: schemeURL) == token)
    #expect(scheme.token(in: httpsURL) == nil)
    let host = InvitationLinks(httpsHost: "parcourses.example")
    #expect(host.link(token: token) == "https://parcourses.example/i/#\(token)")
    #expect(host.token(in: httpsURL) == token)
    // Aucun domaine écrit en dur : l'Info.plist de l'app ne porte pas d'hôte par défaut.
    #expect(InvitationLinks(bundle: .main).httpsHost == nil)
  }

  @Test func serverErrorsBecomeTheInputsOfVector003() {
    #expect(SupabaseGateway.sharingError(PostgrestError(code: "P0001", message: "list_full")).kind == .listFull)
    #expect(SupabaseGateway.sharingError(PostgrestError(code: "42501", message: "not allowed")).kind == .notAllowed)
    #expect(
      SupabaseGateway.sharingError(PostgrestError(code: "42501", message: "email account required")).kind
        == .signInRequired)
    #expect(SupabaseGateway.sharingError(URLError(.notConnectedToInternet)).kind == .offline)
    #expect(SupabaseGateway.sharingError(PostgrestError(code: "XX000", message: "boom")).kind == .unknown)
  }

  @Test func aBroadcastPayloadBecomesASignalWithoutLabel() {
    let list = UUID()
    let message: JSONObject = [
      "event": .string("changed"),
      "payload": .object(["list_id": .string(list.uuidString.lowercased()), "kind": .string("items")]),
    ]
    #expect(SupabaseGateway.signal(from: message) == RealtimeSignal(listId: list, kind: "items"))
    let invitation: JSONObject = ["payload": .object(["list_id": .null, "kind": .string("invitations")])]
    #expect(SupabaseGateway.signal(from: invitation) == RealtimeSignal(listId: nil, kind: "invitations"))
    #expect(SupabaseGateway.signal(from: ["payload": .object([:])]) == nil)
  }

  /// Réponses des RPC, dans la forme renvoyée par PostgREST (microsecondes et décalage horaire).
  @Test func rpcResponsesDecode() throws {
    let decoder = PostgrestClient.Configuration.jsonDecoder
    let list = UUID()
    let sharing = """
      {"list_id": "\(list.uuidString.lowercased())", "role": "owner",
       "owner": {"user_id": "\(hadrien.uuidString.lowercased())", "display_name": "Hadrien", "is_me": true},
       "members": [{"user_id": "\(lea.uuidString.lowercased())", "display_name": null, "role": "editor",
                    "is_me": false, "joined_at": "2026-11-12T10:00:00.123456+00:00"}],
       "invitations": [{"id": "\(UUID().uuidString.lowercased())", "email": "c.martin@exemple.fr", "role": "viewer",
                        "created_at": "2026-11-14T10:00:00.123456+00:00", "expires_at": "2026-11-21T10:00:00+00:00",
                        "sent_count": 2, "expired": false}]}
      """
    let model = try decoder.decode(ListSharingWire.self, from: Data(sharing.utf8)).model
    #expect(model.listId == list && model.role == .owner)
    #expect(model.participants.map(\.role) == [.owner, .editor])
    #expect(model.members.first?.name == "Quelqu'un")
    #expect(model.invitations.first?.role == .viewer && model.invitations.first?.sentCount == 2)
    let acceptance = try decoder.decode(
      [InvitationAcceptanceRow].self,
      from: Data(#"[{"status": "accepted", "list_id": "\#(list.uuidString)", "role": "editor"}]"#.utf8))
    #expect(acceptance.first?.model == InvitationAcceptance(status: "accepted", listId: list, role: .editor))
    #expect(acceptance.first?.model.outcome == .joined)
    let preview = try decoder.decode(
      [InvitationPreviewRow].self,
      from: Data(
        #"[{"status": "rate_limited", "invitation_id": null, "list_id": null, "list_name": null, "inviter_name": null, "role": null, "email_matches": null, "invited_email_masked": null, "expires_at": null}]"#
          .utf8))
    #expect(preview.first?.model.cardState == .rateLimited)
  }

  @Test func texts() {
    let now = t0
    let pending = PendingInvitation(
      id: UUID(), email: "c.martin@exemple.fr", role: .editor, createdAt: now,
      expiresAt: now.addingTimeInterval(7 * 86_400 - 60), sentCount: 1, expired: false)
    #expect(SharingFormat.pendingExpiry(pending, now: now) == "expire dans 7\u{00A0}j")
    #expect(SharingFormat.pendingExpiryAccessibility(pending, now: now) == "expire dans 7 jours")
    #expect(
      SharingFormat.downgraded(ownerName: "Hadrien", dropped: 2)
        == "Hadrien a passé votre accès en lecture seule. Vos 2 dernières modifications n'ont pas été enregistrées.")
    #expect(
      SharingFormat.downgraded(ownerName: "Hadrien", dropped: 0) == "Hadrien a passé votre accès en lecture seule.")
    #expect(
      SharingFormat.invitationTitle(inviter: "Hadrien", listName: nil) == "Hadrien vous invite à une liste de courses")
    #expect(SharingFormat.askOwner("Hadrien") == "Lecture seule. Demandez à Hadrien l'accès en modification.")
    #expect(ShareListModel.message(for: .listFull).hasPrefix("Une liste compte au plus 10 participants"))
  }
}

// MARK: - Signaux temps réel

/// Canal simulé : les événements sont poussés par le test.
private actor FakeTransport: RealtimeTransport {
  private(set) var opened: [UUID] = []
  private(set) var closes = 0
  private var continuation: AsyncStream<RealtimeEvent>.Continuation?

  func userSignals(userId: UUID) async -> AsyncStream<RealtimeEvent> {
    opened.append(userId)
    let (stream, continuation) = AsyncStream<RealtimeEvent>.makeStream()
    self.continuation = continuation
    return stream
  }

  func closeUserSignals() async {
    closes += 1
    continuation?.finish()
    continuation = nil
  }

  func send(_ event: RealtimeEvent) {
    continuation?.yield(event)
  }
}

@MainActor
private final class SignalProbe {
  var pulls = 0
  var invitationReloads = 0
  var sharingReloads: [UUID] = []
  var isEmail = true
  var openSheet: UUID?
}

@MainActor
@Suite(.serialized) struct RealtimeSignalsTests {
  private func make(
    _ transport: FakeTransport?, probe: SignalProbe, account: UUID = lea, groupingWaits: Bool = true
  ) -> RealtimeSignals {
    RealtimeSignals(
      transport: transport,
      dependencies: RealtimeSignals.Dependencies(
        accountId: { account }, isEmailAccount: { probe.isEmail },
        isSharingSheetOpen: { listId in listId != nil && listId == probe.openSheet },
        pull: { probe.pulls += 1 }, reloadInvitations: { probe.invitationReloads += 1 },
        reloadSharing: { probe.sharingReloads.append($0) },
        // Fenêtre de regroupement tenue ouverte : le test décide quand elle se ferme (`flush`).
        sleep: { duration in if groupingWaits { try await Task.sleep(for: .seconds(3600)) } else { _ = duration } }))
  }

  /// Signaux d'une même fenêtre de 300 ms : une seule descente, une seule relecture (vecteur `006` appliqué).
  @Test func signalsWithinTheWindowAreGrouped() {
    let probe = SignalProbe()
    let list = UUID()
    probe.openSheet = list
    let signals = make(nil, probe: probe)
    signals.handle(.signal(RealtimeSignal(listId: list, kind: "items")))
    signals.handle(.signal(RealtimeSignal(listId: list, kind: "items")))
    signals.handle(.signal(RealtimeSignal(listId: list, kind: "members")))
    signals.handle(.signal(RealtimeSignal(listId: nil, kind: "invitations")))
    signals.handle(.signal(RealtimeSignal(listId: UUID(), kind: "members")))
    #expect(probe.pulls == 0)
    signals.flush()
    #expect(probe.pulls == 1)
    #expect(probe.invitationReloads == 1)
    #expect(probe.sharingReloads == [list])
    signals.flush()
    #expect(probe.pulls == 1)
  }

  /// Fenêtre écoulée : les signaux partent d'eux-mêmes.
  @Test func theWindowClosesByItself() async {
    let probe = SignalProbe()
    let signals = make(nil, probe: probe, groupingWaits: false)
    signals.handle(.signal(RealtimeSignal(listId: UUID(), kind: "items")))
    signals.handle(.signal(RealtimeSignal(listId: UUID(), kind: "list")))
    await eventually { probe.pulls > 0 }
    #expect(probe.pulls == 1)
  }

  /// Premier plan : canal du compte, descente à chaque (re)connexion ; arrière-plan : canal fermé.
  @Test func foregroundOpensBackgroundClosesAndEachSubscriptionPulls() async {
    let probe = SignalProbe()
    let transport = FakeTransport()
    let signals = make(transport, probe: probe)
    await signals.foreground()
    await eventually { await transport.opened == [lea] }
    #expect(signals.isOpen)
    await transport.send(.subscribed)
    await eventually { probe.pulls == 1 }
    #expect(probe.pulls == 1)
    // Reconnexion du canal : les signaux manqués ne sont pas rejoués, une descente les rattrape.
    await transport.send(.subscribed)
    await eventually { probe.pulls == 2 }
    #expect(probe.pulls == 2)
    // Déjà ouvert pour ce compte : rien ne change.
    await signals.foreground()
    #expect(await transport.opened == [lea])
    await signals.background()
    #expect(!signals.isOpen)
    #expect(await transport.closes == 1)
  }

  /// Signaux reçus juste avant l'arrière-plan : appliqués, pas perdus.
  @Test func pendingSignalsAreAppliedWhenClosing() async {
    let probe = SignalProbe()
    let transport = FakeTransport()
    let signals = make(transport, probe: probe)
    await signals.foreground()
    signals.handle(.signal(RealtimeSignal(listId: UUID(), kind: "items")))
    await signals.background()
    #expect(probe.pulls == 1)
  }

  /// Compte anonyme : aucun canal.
  @Test func anAnonymousAccountOpensNoChannel() async {
    let probe = SignalProbe()
    probe.isEmail = false
    let transport = FakeTransport()
    let signals = make(transport, probe: probe)
    await signals.foreground()
    #expect(!signals.isOpen)
    #expect(await transport.opened.isEmpty)
  }
}

// MARK: - Rôle durable et `refreshAccess`

@MainActor
@Suite(.serialized) struct SharingSyncTests {
  private func sharedList(_ harness: SyncHarness, role: String) async throws -> (listId: UUID, itemId: UUID, me: UUID) {
    let me = await harness.gateway.account
    let listId = UUID()
    let itemId = UUID()
    await harness.gateway.setPull(
      lists: [ListRow(id: listId, ownerId: hadrien, name: "Courses de la semaine", createdAt: t0, updatedAt: t0)],
      items: [
        ListItemRow(
          id: itemId, listId: listId, productId: nil, label: "Lait", quantity: nil, checkedAt: nil, createdAt: t0,
          updatedAt: t0, updatedBy: hadrien)
      ])
    await harness.gateway.setMembers(
      [ListMemberRow(listId: listId, userId: me, role: role, createdAt: t0, updatedAt: t0)],
      profiles: [
        ProfileRow(userId: hadrien, displayName: "Hadrien", createdAt: t0, updatedAt: t0),
        ProfileRow(userId: me, displayName: "Léa", createdAt: t0, updatedAt: t0),
      ])
    await harness.engine.drain(pull: true)
    return (listId, itemId, me)
  }

  private func list(_ harness: SyncHarness, _ id: UUID) throws -> ShoppingList? {
    try harness.fresh(ShoppingList.self).first { $0.id == id }
  }

  /// La descente pose le rôle durable et les participants (`list_members`, `profiles`).
  @Test func thePullStoresMyRoleAndTheParticipants() async throws {
    let harness = try SyncHarness()
    let (listId, _, _) = try await sharedList(harness, role: "editor")
    let local = try #require(try list(harness, listId))
    #expect(local.role == .editor)
    #expect(local.participants.map(\.displayName) == ["Hadrien", "Léa"])
    #expect(local.participants.map(\.isMe) == [false, true])
    #expect(local.isShared)
    // Une liste créée ici reste à soi.
    let mine = try harness.lists.createList(name: "Mienne", at: t0)
    await harness.engine.drain(pull: true)
    #expect(try list(harness, mine.id)?.role == .owner)
  }

  /// Rôle abaissé à la descente : les écritures en attente de la liste sont jetées, la liste rechargée, le message
  /// annoncé.
  @Test func aRoleLoweredAtThePullDropsPendingWritesAndAnnouncesIt() async throws {
    let harness = try SyncHarness()
    let (listId, itemId, me) = try await sharedList(harness, role: "editor")
    let recorder = AccessChangeRecorder(listId: listId)
    defer { recorder.stop() }
    await harness.gateway.setMembers(
      [ListMemberRow(listId: listId, userId: me, role: "viewer", createdAt: t0, updatedAt: t0)],
      profiles: [ProfileRow(userId: hadrien, displayName: "Hadrien", createdAt: t0, updatedAt: t0)])
    harness.clock.advance(120)
    await harness.engine.drain(pull: true)
    #expect(try list(harness, listId)?.role == .viewer)
    #expect(recorder.changes.map(\.kind) == [.downgraded(droppedChanges: 0)])
    #expect(recorder.changes.first?.ownerName == "Hadrien")
    #expect(try harness.fresh(ListItem.self).contains { $0.id == itemId })
  }

  /// Vecteur `003` sans pierre tombale, liste d'autrui : `refreshAccess` relit `list_sharing`. Lecteur : l'entrée part,
  /// la valeur du serveur revient, « Vos dernières modifications… » compte l'écriture jetée.
  @Test func refreshAccessAsAViewerDropsTheEntriesOfTheList() async throws {
    let harness = try SyncHarness()
    let (listId, itemId, me) = try await sharedList(harness, role: "editor")
    let recorder = AccessChangeRecorder(listId: listId)
    defer { recorder.stop() }
    await harness.gateway.setMembers(
      [ListMemberRow(listId: listId, userId: me, role: "viewer", createdAt: t0, updatedAt: t0)],
      profiles: [ProfileRow(userId: hadrien, displayName: "Hadrien", createdAt: t0, updatedAt: t0)])
    await harness.gateway.setReadOnlyItems([itemId])
    await harness.gateway.clearCalls()
    try harness.lists.setChecked(itemId: itemId, checkedAt: t0, at: t0)
    await harness.engine.drain()
    #expect(await harness.gateway.calls.contains("listSharing"))
    #expect(try harness.entries().isEmpty)
    #expect(try harness.fresh(ListItem.self).first { $0.id == itemId }?.checkedAt == nil)
    #expect(try list(harness, listId)?.role == .viewer)
    #expect(recorder.changes.map(\.kind) == [.downgraded(droppedChanges: 1)])
  }

  /// `not allowed` : la liste n'est plus accessible, elle quitte l'appareil avec le message de la maquette.
  @Test func refreshAccessRemovesAListThatIsNoLongerReadable() async throws {
    let harness = try SyncHarness()
    let (listId, itemId, _) = try await sharedList(harness, role: "editor")
    let recorder = AccessChangeRecorder(listId: listId)
    defer { recorder.stop() }
    await harness.gateway.setHiddenLists([listId])
    try await harness.engine.refreshAccess(listId: listId)
    #expect(try list(harness, listId) == nil)
    #expect(try !harness.fresh(ListItem.self).contains { $0.id == itemId })
    #expect(recorder.changes.map(\.kind) == [.removed])
    #expect(recorder.changes.first?.listName == "Courses de la semaine")
  }

  /// Retiré par le propriétaire : la descente retire la liste et l'annonce.
  @Test func aListSharedWithMeThatDisappearsIsAnnounced() async throws {
    let harness = try SyncHarness()
    let (listId, _, _) = try await sharedList(harness, role: "viewer")
    let recorder = AccessChangeRecorder(listId: listId)
    defer { recorder.stop() }
    await harness.gateway.setHiddenLists([listId])
    harness.clock.advance(120)
    await harness.engine.drain(pull: true)
    #expect(try list(harness, listId) == nil)
    #expect(recorder.changes.map(\.kind) == [.removed])
  }
}

// MARK: - Modèles d'écran

@MainActor
@Suite(.serialized) struct SharingScreenModelTests {
  private func center(
    _ scenario: UITestSharingGateway.Scenario, email: Bool = true, synchronized: (() -> Void)? = nil,
    forgotten: ((UUID) -> Void)? = nil
  ) -> SharingCenter {
    SharingCenter(
      gateway: UITestSharingGateway(scenario: scenario), transport: nil,
      dependencies: SharingCenter.Dependencies(
        isEmailAccount: { email }, accountEmail: { "tom@exemple.fr" }, synchronize: { synchronized?() },
        listExists: { $0 == UITestSharingGateway.listId }, forgetList: { forgotten?($0) }, accountId: { hadrien }),
      monitorsNetwork: false)
  }

  @Test func theOwnerSeesMembersInvitationsAndInvites() async throws {
    let center = center(.owner)
    let model = center.makeShareModel(listId: UITestSharingGateway.listId, listName: "Courses de la semaine")
    var copied: [String] = []
    model.copy = { copied.append($0) }
    await model.load()
    #expect(model.state == .loaded && model.isOwner)
    #expect(model.members.map(\.name) == ["Hadrien", "Léa", "Tom"])
    #expect(model.invitations.map(\.email) == ["c.martin@exemple.fr"])

    model.email = "pas-une-adresse"
    await model.send()
    #expect(model.fieldError == "Cette adresse ne semble pas valide.")
    model.email = "lea@exemple.fr"
    await model.send()
    #expect(model.fieldError == "Cette personne fait déjà partie de la liste.")
    model.email = " Nouveau@Exemple.fr "
    model.role = .viewer
    await model.send()
    #expect(model.fieldError == nil)
    #expect(model.email.isEmpty)
    #expect(model.toast == "Invitation envoyée à nouveau@exemple.fr")
    #expect(model.invitations.first?.email == "nouveau@exemple.fr")
    #expect(model.invitations.first?.role == .viewer)

    // E-mail non parti : la carte propose le lien.
    model.email = "sans-mail@exemple.fr"
    await model.send()
    #expect(model.mailFailure != nil)
    model.copyFailedMailLink()
    #expect(copied == ["parcourses://invitation#\(UITestSharingGateway.token)"])

    let pending = try #require(model.invitations.first { $0.email == "c.martin@exemple.fr" })
    await model.copyLink(pending)
    #expect(model.toast?.hasPrefix("Nouveau lien copié") == true)
    await model.revoke(pending)
    #expect(!model.invitations.contains { $0.email == "c.martin@exemple.fr" })

    let leaRow = try #require(model.members.first { $0.name == "Léa" })
    await model.setRole(leaRow, to: .viewer)
    #expect(model.toast == "Léa passe en lecture seule.")
    #expect(model.members.first { $0.name == "Léa" }?.role == .viewer)
    await model.remove(leaRow)
    #expect(!model.members.contains { $0.name == "Léa" })
  }

  @Test func aMemberSeesTheMembersAndCanLeave() async {
    var forgotten: [UUID] = []
    let center = center(.viewer, forgotten: { forgotten.append($0) })
    let model = center.makeShareModel(listId: UITestSharingGateway.listId, listName: "Courses de la semaine")
    await model.load()
    #expect(!model.isOwner)
    #expect(model.ownerName == "Hadrien")
    #expect(model.invitations.isEmpty)
    await model.leave()
    #expect(model.didLeave)
    #expect(forgotten == [UITestSharingGateway.listId])
  }

  @Test func aReceivedInvitationIsAcceptedThenTheListOpens() async throws {
    var synchronized = 0
    let center = center(.invitation, synchronized: { synchronized += 1 })
    await center.loadInvitations()
    let invitation = try #require(center.invitations.first)
    let card = center.makeCard(for: invitation)
    #expect(card.title == "Hadrien vous invite à «\u{00A0}Courses de la semaine\u{00A0}»")
    #expect(card.canAccept && card.canDecline)
    let opened = await card.accept()
    #expect(opened == UITestSharingGateway.listId)
    #expect(synchronized == 1)
    #expect(center.invitations.isEmpty)
  }

  @Test func aLinkOpenedOnAnAnonymousAccountAsksToSignInFirst() async throws {
    let center = center(.invitation, email: false)
    #expect(center.open(url: URL(string: "parcourses://invitation#\(UITestSharingGateway.token)")!))
    #expect(!center.open(url: URL(string: "https://evil.example/i/#\(UITestSharingGateway.token)")!))
    let token = try #require(center.openedLink?.token)
    let card = center.makeCard(token: token)
    await card.load()
    #expect(card.phase == .signInRequired)
  }

  @Test func aLinkForAnotherAddressWarnsBeforeAccepting() async {
    let center = center(.invitation)
    let card = center.makeCard(token: UITestSharingGateway.token)
    await card.load()
    #expect(card.state == .otherAddress)
    #expect(card.canAccept && !card.canDecline)
    #expect(card.otherAddressBody.contains("c•••@exemple.fr"))
    #expect(card.otherAddressBody.contains("tom@exemple.fr"))
    #expect(await card.accept() == UITestSharingGateway.listId)
  }
}

// MARK: - Mode courses à deux

@MainActor
@Suite(.serialized) struct SharedShoppingTests {
  /// Léa coche « Lait » pendant mes courses : la ligne passe au panier avec son initiale, sans coche de visite ici.
  @Test func anItemCheckedByAnotherMemberGoesToTheBasketWithoutAVisitCheck() async throws {
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let context = container.mainContext
    let lists = SwiftDataListRepository(context: context, author: { hadrien })
    let visits = SwiftDataVisitRepository(context: context, author: { hadrien })
    let stores = SwiftDataStoreRepository(context: context)
    let categories = SwiftDataCategoryRepository(context: context)
    try categories.seedIfNeeded()
    let analyzer = try EntryAnalyzer()
    let list = try lists.createList(name: "Courses de la semaine", at: t0)
    list.participants = [
      ListParticipant(userId: hadrien, displayName: "Hadrien", role: .owner, isMe: true, joinedAt: nil),
      ListParticipant(userId: lea, displayName: "Léa", role: .editor, isMe: false, joinedAt: t0),
    ]
    try context.save()
    let milk = try lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: "2", productId: nil, categoryId: "dairy", at: t0
    )
    _ = try lists.addItem(
      listId: list.id, label: "Pain", normalizedName: "pain", quantity: nil, productId: nil, categoryId: "bakery",
      at: t0)
    #expect(milk.updatedBy == hadrien)
    let storeId = UUID()
    try stores.upsertStore(
      id: storeId, name: "Leclerc", chain: nil, address: nil, lastDistanceM: nil, organicAisle: false)
    let session = ShoppingSession(
      listId: list.id, storeId: storeId, lists: lists, visits: visits, stores: stores, categories: categories,
      analyzer: analyzer, cache: GraphSnapshotCache(graphs: SwiftDataGraphRepository(context: context), gateway: nil),
      settleDelay: .milliseconds(1), highlightDelay: .milliseconds(1), accountId: { hadrien })
    await session.start()
    let visitId = try #require(session.visitId)

    // Arrivée par la descente : coché par Léa.
    milk.checkedAt = t0.addingTimeInterval(60)
    milk.updatedBy = lea
    try context.save()
    session.syncDidChange()
    // La ligne se coche à sa place, puis glisse au panier au tri suivant.
    #expect(session.toBuy.first { $0.id == milk.id }?.isChecked == true)
    await session.waitUntilSettled()
    let basket = try #require(session.basket.first { $0.id == milk.id })
    #expect(basket.authorMark == "L" && basket.authorName == "Léa")
    #expect(try visits.checks(visitId: visitId).isEmpty)
    #expect(session.lastAnnouncement == "Léa a pris Lait. 1 restant.")

    // La liste quitte l'appareil (retrait) : les courses s'arrêtent.
    try lists.forgetList(id: list.id)
    session.syncDidChange()
    #expect(session.accessLost)
  }
}
