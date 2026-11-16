import Domain
import Foundation
import MachO
import Supabase
import SwiftData
import SwiftUI
import Testing
import UIKit

@testable import Parcourses

private nonisolated let t0 = syncEpoch
private let hadrien = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let lea = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let tom = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

/// Hôte https du build (`PARCOURSES_INVITATION_HOST`), jamais écrit en dur dans les tests.
private nonisolated let buildHost = InvitationLinks(bundle: .main).httpsHost

/// Entitlements signés de l'app hôte : au build simulateur, Xcode les écrit dans la section `__TEXT,__entitlements` de
/// l'exécutable (XML), que l'on relit ici plutôt que le fichier source.
private func signedEntitlements() throws -> [String: Any] {
  let executable = try #require(Bundle.main.executableURL?.lastPathComponent)
  for index in 0..<_dyld_image_count() {
    guard let name = _dyld_get_image_name(index), String(cString: name).hasSuffix(".app/\(executable)"),
      let header = _dyld_get_image_header(index)
    else { continue }
    var size: UInt = 0
    let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
    let section = try #require(getsectiondata(header64, "__TEXT", "__entitlements", &size))
    // Section complétée de zéros : le XML s'arrête au premier.
    let data = Data(bytes: section, count: Int(size)).prefix { $0 != 0 }
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  }
  Issue.record("exécutable \(executable) introuvable parmi les images chargées")
  return [:]
}

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

  @Test func anEmptyHostKeepsOnlyTheScheme() throws {
    let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCde"
    for empty in ["", "  ", nil] {
      let scheme = InvitationLinks(httpsHost: empty)
      #expect(scheme.httpsHost == nil)
      #expect(scheme.link(token: token) == "parcourses://invitation#\(token)")
      let schemeURL = try #require(URL(string: "parcourses://invitation#\(token)"))
      let httpsURL = try #require(URL(string: "https://parcourses.example/i/#\(token)"))
      #expect(scheme.token(in: schemeURL) == token)
      #expect(scheme.token(in: httpsURL) == nil)
    }
    let host = InvitationLinks(httpsHost: "parcourses.example")
    #expect(host.link(token: token) == "https://parcourses.example/i/#\(token)")
  }

  /// Lot 87.7 : le domaine associé effectivement signé (section `__TEXT,__entitlements` de l'exécutable, posée par Xcode
  /// au build simulateur) suit l'hôte du build ; sans hôte, l'hôte réservé `invitation.invalid`.
  @Test func theSignedAssociatedDomainFollowsTheBuildHost() throws {
    let entitlements = try signedEntitlements()
    let domains = entitlements["com.apple.developer.associated-domains"] as? [String]
    #expect(domains == ["applinks:\(buildHost ?? "invitation.invalid")"])
  }

  /// Lot 87.7 (Q2) : avec un hôte de build, « Copier le lien » donne `https://<hôte>/i/#<jeton>`.
  @Test(.enabled(if: buildHost != nil)) func theBuildHostMakesHttpsLinks() throws {
    let host = try #require(buildHost)
    let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCde"
    #expect(InvitationLinks(bundle: .main).link(token: token) == "https://\(host)/i/#\(token)")
  }

  /// Vecteur `001` rejoué avec l'hôte du build à la place de `parcourses.example` : mêmes réponses.
  @Test(.enabled(if: buildHost != nil)) func vector001HoldsWithTheBuildHost() throws {
    let build = InvitationLinks(bundle: .main)
    let host = try #require(buildHost)
    let file = try #require(SharingVectorFile.all.first { $0.name.hasPrefix("001-") })
    let object = try #require(try JSONSerialization.jsonObject(with: file.data) as? [String: Any])
    let cases = try #require(object["cases"] as? [[String: Any]])
    var played = 0
    for testCase in cases {
      let input = try #require(testCase["input"] as? [String: Any])
      // Cas « sans hôte configuré » : sans objet, le build en a un.
      guard input["httpsHost"] is String else { continue }
      let raw = try #require(input["url"] as? String).replacingOccurrences(of: "parcourses.example", with: host)
        .replacingOccurrences(of: "Parcourses.Example", with: host.uppercased())
      let url = try #require(URL(string: raw))
      #expect(build.token(in: url) == testCase["expected"] as? String, "\(testCase["name"] ?? "?")")
      played += 1
    }
    #expect(played >= 6)
  }

  /// Seul `https://<hôte du build>/i/#<jeton>` ouvre une invitation : autre hôte, http, autre chemin (même proche),
  /// paramètres, port ou jeton hors du fragment sont refusés, comme sur Android. `HOST` : l'hôte du build.
  @Test(
    .enabled(if: buildHost != nil),
    arguments: [
      "https://evil.example/i/#",
      "https://HOST.evil.example/i/#",
      "https://evil.example/HOST/i/#",
      "http://HOST/i/#",
      "https://HOST/#",
      "https://HOST/i#",
      "https://HOST/i/x#",
      "https://HOST/i//#",
      "https://HOST/x/i/#",
      "https://HOST/I/#",
      "https://HOST/i/?ref=mail#",
      "https://HOST:8443/i/#",
      "https://user@HOST/i/#",
    ])
  func otherHttpsLinksAreRefused(_ pattern: String) throws {
    let host = try #require(buildHost)
    let url = try #require(
      URL(string: pattern.replacingOccurrences(of: "HOST", with: host) + UITestSharingGateway.token))
    #expect(InvitationLinks(bundle: .main).token(in: url) == nil)
  }

  /// Lien universel livré par `onContinueUserActivity` (navigation web) : même carte que le schéma. Un second lien
  /// remplace le premier ; le même lien livré deux fois garde la feuille présentée ; une autre activité est ignorée.
  @Test(.enabled(if: buildHost != nil)) func aUniversalLinkOpensTheSameCardAsTheScheme() throws {
    let host = try #require(buildHost)
    let center = SharingCenter(
      gateway: nil, transport: nil, links: InvitationLinks(bundle: .main), monitorsNetwork: false)
    let first = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCde"
    let second = "ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210_-ZyXwV"

    let web = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    web.webpageURL = URL(string: "https://\(host)/i/#\(first)")
    #expect(center.open(userActivity: web))
    let opened = try #require(center.openedLink)
    #expect(opened.token == first)
    // Même lien par `onOpenURL` : la feuille déjà présentée reste.
    #expect(center.open(url: try #require(web.webpageURL)))
    #expect(center.openedLink == opened)

    // Second lien, par le schéma : il remplace le premier.
    #expect(center.open(url: try #require(URL(string: "parcourses://invitation#\(second)"))))
    #expect(center.openedLink?.token == second)
    #expect(center.openedLink != opened)
    // Puis de nouveau le premier, en lien universel.
    #expect(center.open(url: try #require(URL(string: "https://\(host)/i/#\(first)"))))
    #expect(center.openedLink?.token == first)

    // Lien refusé ou autre activité : la feuille présentée ne change pas.
    let shown = center.openedLink
    let foreign = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    foreign.webpageURL = URL(string: "https://evil.example/i/#\(second)")
    #expect(!center.open(userActivity: foreign))
    let handoff = NSUserActivity(activityType: "app.parcourses.other")
    handoff.webpageURL = URL(string: "https://\(host)/i/#\(second)")
    #expect(!center.open(userActivity: handoff))
    #expect(!center.open(userActivity: NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)))
    #expect(center.openedLink == shown)
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

/// Attentes injectées dans `RealtimeSignals` : suspendues jusqu'à leur annulation, comptées.
@MainActor
private final class SleepProbe {
  private(set) var started = 0
  private(set) var cancelled = 0

  func sleep(_ duration: Duration) async throws {
    started += 1
    do {
      try await Task.sleep(for: .seconds(3600))
    } catch {
      cancelled += 1
      throw error
    }
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
    let signals = RealtimeSignals(
      transport: transport,
      dependencies: RealtimeSignals.Dependencies(
        accountId: { account }, isEmailAccount: { probe.isEmail },
        isSharingSheetOpen: { listId in listId != nil && listId == probe.openSheet },
        pull: { probe.pulls += 1 }, reloadInvitations: { probe.invitationReloads += 1 },
        reloadSharing: { probe.sharingReloads.append($0) },
        // Fenêtre de regroupement tenue ouverte : le test décide quand elle se ferme (`flush`).
        sleep: { duration in if groupingWaits { try await Task.sleep(for: .seconds(3600)) } else { _ = duration } }))
    // Scène active, comme après `.active`.
    signals.enteredForeground()
    return signals
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
    // Coche faite ici, encore en file au moment de la descente (envoi pas encore dû) ; le rôle baisse ailleurs.
    try harness.lists.setChecked(itemId: itemId, checkedAt: t0, at: t0)
    let entry = try #require(try harness.entries().first { $0.entityId == itemId })
    entry.nextAttemptAt = t0.addingTimeInterval(86_400)
    try harness.context.save()
    await harness.gateway.setMembers(
      [ListMemberRow(listId: listId, userId: me, role: "viewer", createdAt: t0, updatedAt: t0)],
      profiles: [ProfileRow(userId: hadrien, displayName: "Hadrien", createdAt: t0, updatedAt: t0)])
    harness.clock.advance(120)
    await harness.engine.drain(pull: true)
    #expect(try list(harness, listId)?.role == .viewer)
    #expect(recorder.changes.map(\.kind) == [.downgraded(droppedChanges: 1)])
    #expect(recorder.changes.first?.ownerName == "Hadrien")
    // L'écriture jetée n'est jamais partie, la file est vide, l'article reprend la valeur du serveur.
    #expect(try harness.fresh(OutboxEntry.self).isEmpty)
    #expect(await !harness.gateway.calls.contains("updateItem"))
    #expect(try harness.fresh(ListItem.self).first { $0.id == itemId }?.checkedAt == nil)
  }

  /// Relecture de #100 : une descente coupée entre l'arrivée de la liste et la lecture des membres la laisse en lecture
  /// seule, jamais en propriétaire. La descente suivante pose le vrai rôle, sans message.
  @Test func aPullCutAfterTheListArrivesLeavesItReadOnly() async throws {
    let harness = try SyncHarness()
    let me = await harness.gateway.account
    let listId = UUID()
    let recorder = AccessChangeRecorder(listId: listId)
    defer { recorder.stop() }
    await harness.gateway.setPull(
      lists: [ListRow(id: listId, ownerId: hadrien, name: "Courses de la semaine", createdAt: t0, updatedAt: t0)])
    await harness.gateway.setMembers(
      [ListMemberRow(listId: listId, userId: me, role: "editor", createdAt: t0, updatedAt: t0)],
      profiles: [ProfileRow(userId: hadrien, displayName: "Hadrien", createdAt: t0, updatedAt: t0)])
    await harness.gateway.failAlways("fetchListMembers", with: .network)
    await harness.engine.drain(pull: true)
    let arrived = try #require(try list(harness, listId))
    #expect(arrived.role == .viewer)
    #expect(!SharingDecisions.roleCapabilities(arrived.role).canShare)

    await harness.gateway.failAlways("fetchListMembers", with: nil)
    harness.clock.advance(SyncRetryPolicy.pullRetryInterval + 1)
    await harness.engine.drain(pull: true)
    #expect(try list(harness, listId)?.role == .editor)
    #expect(recorder.changes.isEmpty)
  }

  /// Relecture Android de #87 (a) : après la migration V4→V5, une liste d'un autre compte déjà sur l'appareil passe en
  /// lecture seule au lancement ; les miennes, et celles dont les participants sont lus, ne bougent pas.
  @Test func theLaunchRepairMakesForeignListsReadOnly() throws {
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let context = container.mainContext
    let foreign = ShoppingList(name: "De Hadrien", syncState: .synced, ownerId: hadrien)
    let mine = ShoppingList(name: "À moi", syncState: .synced, ownerId: lea)
    let local = ShoppingList(name: "Jamais envoyée")
    let known = ShoppingList(
      name: "Rôle déjà lu", syncState: .synced, ownerId: hadrien, role: .editor,
      participants: [ListParticipant(userId: hadrien, displayName: "Hadrien", role: .owner, isMe: false, joinedAt: nil)]
    )
    [foreign, mine, local, known].forEach(context.insert)
    try context.save()

    #expect(try ListRoleRepair.apply(in: context, me: nil) == 0)
    #expect(try ListRoleRepair.apply(in: context, me: lea) == 1)
    #expect(foreign.role == .viewer)
    #expect(mine.role == .owner && local.role == .owner && known.role == .editor)
    #expect(try ListRoleRepair.apply(in: context, me: lea) == 0)
  }

  /// Relecture de #100, bloquant 1 : aucune écriture partagée sur une liste en lecture seule, par aucun dépôt.
  @Test func repositoriesRefuseWritesOnAReadOnlyList() throws {
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let context = container.mainContext
    let lists = SwiftDataListRepository(context: context)
    let visits = SwiftDataVisitRepository(context: context)
    let list = try lists.createList(name: "Partagée", at: t0)
    let milk = try lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    let visit = try visits.startVisit(storeId: UUID(), listId: list.id, listWasSorted: false, at: t0)
    list.role = .viewer
    try context.save()
    let entries = try context.fetchCount(FetchDescriptor<OutboxEntry>())

    let readOnly = RepositoryError.readOnly(list.id)
    #expect(throws: readOnly) {
      _ = try lists.addItem(
        listId: list.id, label: "Pain", normalizedName: "pain", quantity: nil, productId: nil, categoryId: "bakery",
        at: t0)
    }
    #expect(throws: readOnly) { try lists.setChecked(itemId: milk.id, checkedAt: t0, at: t0) }
    #expect(throws: readOnly) { try lists.deleteItem(id: milk.id) }
    #expect(throws: readOnly) {
      try lists.updateItem(
        itemId: milk.id, label: "Lait", normalizedName: "lait", categoryId: "dairy", quantity: "2", at: t0)
    }
    #expect(throws: readOnly) { try lists.renameList(id: list.id, name: "Autre", at: t0) }
    #expect(throws: readOnly) { try lists.deleteList(id: list.id, at: t0) }
    #expect(throws: readOnly) {
      _ = try visits.checkItem(
        visitId: visit.id, itemId: milk.id, subject: .category("dairy"), checkedAt: t0, sendAfter: 0)
    }
    #expect(throws: readOnly) {
      _ = try visits.addCheck(visitId: visit.id, itemId: milk.id, subject: .category("dairy"), checkedAt: t0)
    }
    // Champ local, rien ne part : les introuvables restent réglables (fin des courses).
    try lists.setNotFound(itemId: milk.id, notFoundAt: t0, at: t0)
    #expect(try context.fetchCount(FetchDescriptor<OutboxEntry>()) == entries)
    #expect(milk.checkedAt == nil)
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
    #expect(copied == [InvitationLinks().link(token: UITestSharingGateway.token)])

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
    #expect(session.accessEnd == .removed)
  }

  /// Relecture de #100, bloquant 1 : Léa fait les courses quand son rôle passe lecteur. Les courses s'arrêtent
  /// (« Terminer » seulement), plus aucune coche ne s'écrit, et « Terminer » clôt la visite avec les coches déjà faites.
  @Test func aMemberLoweredToViewerWhileShoppingCanOnlyFinish() async throws {
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let context = container.mainContext
    let lists = SwiftDataListRepository(context: context, author: { lea })
    let visits = SwiftDataVisitRepository(context: context, author: { lea })
    let stores = SwiftDataStoreRepository(context: context)
    let categories = SwiftDataCategoryRepository(context: context)
    try categories.seedIfNeeded()
    let list = try lists.createList(name: "Courses de la semaine", at: t0)
    list.ownerId = hadrien
    list.role = .editor
    list.participants = [
      ListParticipant(userId: hadrien, displayName: "Hadrien", role: .owner, isMe: false, joinedAt: nil),
      ListParticipant(userId: lea, displayName: "Léa", role: .editor, isMe: true, joinedAt: t0),
    ]
    try context.save()
    for (label, category) in [("Lait", "dairy"), ("Pain", "bakery")] {
      _ = try lists.addItem(
        listId: list.id, label: label, normalizedName: label.lowercased(), quantity: nil, productId: nil,
        categoryId: category, at: t0)
    }
    let storeId = UUID()
    try stores.upsertStore(
      id: storeId, name: "Leclerc", chain: nil, address: nil, lastDistanceM: nil, organicAisle: false)
    let session = ShoppingSession(
      listId: list.id, storeId: storeId, lists: lists, visits: visits, stores: stores, categories: categories,
      analyzer: try EntryAnalyzer(),
      cache: GraphSnapshotCache(graphs: SwiftDataGraphRepository(context: context), gateway: nil),
      settleDelay: .milliseconds(1), highlightDelay: .milliseconds(1), accountId: { lea })
    await session.start()
    let visitId = try #require(session.visitId)
    session.toggle(try #require(session.toBuy.first))
    await session.waitUntilSettled()
    #expect(try visits.checks(visitId: visitId).count == 1)

    // Rôle abaissé par la descente.
    list.role = .viewer
    try context.save()
    session.syncDidChange()
    #expect(session.accessEnd == .readOnly(ownerName: "Hadrien"))
    #expect(SharingFormat.downgradedTitle(ownerName: "Hadrien") == "Hadrien a passé votre accès en lecture seule.")
    // Un toucher passé sous la feuille ne coche rien.
    session.toggle(try #require(session.toBuy.first { !$0.isChecked }))
    #expect(try visits.checks(visitId: visitId).count == 1)

    session.finish(keepRemaining: true)
    #expect(session.summary?.checkedCount == 1)
    #expect(try visits.visit(id: visitId)?.endedAt != nil)
  }

  /// Contre-relecture de #100 : le rôle passe lecteur pendant le choix du magasin ou la préparation. `start()` relit
  /// l'accès : aucune visite ne s'ouvre, « Terminer » seulement. `resume()` aussi : la visite reprise se clôt avec les
  /// coches déjà faites.
  @Test func aRoleLoweredBeforeTheShoppingStartsOpensNoVisit() async throws {
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let context = container.mainContext
    let lists = SwiftDataListRepository(context: context, author: { lea })
    let visits = SwiftDataVisitRepository(context: context, author: { lea })
    let stores = SwiftDataStoreRepository(context: context)
    let categories = SwiftDataCategoryRepository(context: context)
    try categories.seedIfNeeded()
    let analyzer = try EntryAnalyzer()
    let list = try lists.createList(name: "Courses de la semaine", at: t0)
    list.ownerId = hadrien
    list.role = .editor
    list.participants = [
      ListParticipant(userId: hadrien, displayName: "Hadrien", role: .owner, isMe: false, joinedAt: nil),
      ListParticipant(userId: lea, displayName: "Léa", role: .editor, isMe: true, joinedAt: t0),
    ]
    try context.save()
    _ = try lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    let storeId = UUID()
    try stores.upsertStore(
      id: storeId, name: "Leclerc", chain: nil, address: nil, lastDistanceM: nil, organicAisle: false)
    func session() -> ShoppingSession {
      ShoppingSession(
        listId: list.id, storeId: storeId, lists: lists, visits: visits, stores: stores, categories: categories,
        analyzer: analyzer, cache: GraphSnapshotCache(graphs: SwiftDataGraphRepository(context: context), gateway: nil),
        settleDelay: .milliseconds(1), highlightDelay: .milliseconds(1), accountId: { lea })
    }

    // Visite en cours, une coche faite.
    let shopping = session()
    await shopping.start()
    let visitId = try #require(shopping.visitId)
    shopping.toggle(try #require(shopping.toBuy.first))
    await shopping.waitUntilSettled()
    // Passée lecteur pendant que l'app était fermée, après la vérification du lancement : la reprise s'arrête.
    list.role = .viewer
    try context.save()
    let visit = try #require(try visits.openVisit())
    let resumed = session()
    await resumed.resume(visit: visit)
    #expect(resumed.accessEnd == .readOnly(ownerName: "Hadrien"))
    resumed.finish(keepRemaining: true)
    #expect(try visits.visit(id: visitId)?.endedAt != nil)
    #expect(try visits.checks(visitId: visitId).count == 1)

    // Nouveau départ, lecteur : aucune visite.
    let refused = session()
    await refused.start()
    #expect(refused.accessEnd == .readOnly(ownerName: "Hadrien"))
    #expect(refused.visitId == nil)
    #expect(try visits.openVisit() == nil)
  }
}

// MARK: - Relecture de #100

/// Compte qui ne se lit qu'à la demande du test : une ouverture du canal reste suspendue sur `accountId`.
private actor AccountGate {
  private var waiters: [CheckedContinuation<UUID?, Never>] = []
  var waiting: Int { waiters.count }

  func wait() async -> UUID? {
    await withCheckedContinuation { waiters.append($0) }
  }

  func release(_ id: UUID?) {
    for waiter in waiters { waiter.resume(returning: id) }
    waiters = []
  }
}

/// Transport dont l'ouverture du canal reste suspendue jusqu'à `release()` : un `close()` peut arriver pendant ce temps.
private actor SlowJoinTransport: RealtimeTransport {
  enum Step: Equatable {
    case joined
    case closed
  }

  private(set) var steps: [Step] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  var waiting: Int { waiters.count }

  func userSignals(userId: UUID) async -> AsyncStream<RealtimeEvent> {
    await withCheckedContinuation { waiters.append($0) }
    steps.append(.joined)
    return AsyncStream { _ in
      // Canal sans événement.
    }
  }

  func closeUserSignals() async {
    steps.append(.closed)
  }

  func release() {
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

@MainActor
@Suite(.serialized) struct SharingReviewTests {
  private func gated(_ transport: FakeTransport, gate: AccountGate) -> RealtimeSignals {
    let signals = RealtimeSignals(
      transport: transport,
      dependencies: RealtimeSignals.Dependencies(accountId: { await gate.wait() }, isEmailAccount: { true }))
    signals.enteredForeground()
    return signals
  }

  /// Mineur 3 : l'app passe en arrière-plan pendant que le compte est relu ; le canal ne s'ouvre pas après coup.
  @Test func goingToTheBackgroundWhileTheAccountIsReadOpensNoChannel() async {
    let transport = FakeTransport()
    let gate = AccountGate()
    let signals = gated(transport, gate: gate)
    let opening = Task { await signals.foreground() }
    await eventually { await gate.waiting == 1 }
    signals.enteredBackground()
    await gate.release(lea)
    await opening.value
    #expect(!signals.isOpen)
    #expect(await transport.opened.isEmpty)
    // Retour au premier plan : le canal s'ouvre de nouveau.
    signals.enteredForeground()
    let reopening = Task { await signals.foreground() }
    await eventually { await gate.waiting == 1 }
    await gate.release(lea)
    await reopening.value
    #expect(signals.isOpen)
    #expect(await transport.opened == [lea])
    await signals.background()
  }

  /// Contre-relecture de #100 : tant que la scène n'est pas passée à `.active`, aucun canal ne s'ouvre (scène connectée
  /// en arrière-plan).
  @Test func noChannelOpensBeforeTheSceneIsActive() async {
    let transport = FakeTransport()
    let signals = RealtimeSignals(
      transport: transport,
      dependencies: RealtimeSignals.Dependencies(accountId: { lea }, isEmailAccount: { true }))
    #expect(!signals.isInForeground)
    await signals.foreground()
    #expect(!signals.isOpen)
    #expect(await transport.opened.isEmpty)
    signals.enteredForeground()
    await signals.foreground()
    #expect(signals.isOpen)
    await eventually { await transport.opened == [lea] }
    await signals.background()
  }

  /// Contre-relecture de #100 : l'arrière-plan arrive pendant que le canal se rejoint. Le canal rejoint après coup se
  /// referme : la dernière opération du transport est une fermeture.
  @Test func closingWhileTheChannelIsJoiningClosesIt() async {
    let transport = SlowJoinTransport()
    let signals = RealtimeSignals(
      transport: transport,
      dependencies: RealtimeSignals.Dependencies(
        accountId: { lea }, isEmailAccount: { true }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
    signals.enteredForeground()
    await signals.foreground()
    await eventually { await transport.waiting == 1 }
    let closing = Task { await signals.background() }
    // La fermeture attend la fin de l'ouverture : rien n'est encore fermé.
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await transport.steps.isEmpty)
    await transport.release()
    await closing.value
    #expect(!signals.isOpen)
    let steps = await transport.steps
    #expect(steps.first == .joined)
    #expect(steps.last == .closed)
  }

  /// Relecture de #107 : une coche faite juste après l'abonnement peut suivre la première descente sans que son signal
  /// arrive. Une seconde descente part 2,5 s après `.subscribed`.
  @Test func aSecondPullFollowsEachSubscription() async {
    let probe = SignalProbe()
    var waits: [Duration] = []
    let signals = RealtimeSignals(
      transport: nil,
      dependencies: RealtimeSignals.Dependencies(pull: { probe.pulls += 1 }, sleep: { waits.append($0) }))
    signals.handle(.subscribed)
    #expect(probe.pulls == 1)
    await eventually { probe.pulls == 2 }
    #expect(probe.pulls == 2)
    #expect(waits == [RealtimeSignals.subscribedFollowUpDelay])
    #expect(RealtimeSignals.subscribedFollowUpDelay == .milliseconds(2500))
  }

  /// Relecture de #107 : la seconde descente est unique (un nouvel abonnement remplace celle en attente) et annulée à la
  /// fermeture du canal.
  @Test func theFollowUpPullIsUniqueAndCancelledOnClose() async {
    let probe = SignalProbe()
    let sleeps = SleepProbe()
    let transport = FakeTransport()
    let signals = RealtimeSignals(
      transport: transport,
      dependencies: RealtimeSignals.Dependencies(
        accountId: { lea }, isEmailAccount: { true }, pull: { probe.pulls += 1 },
        sleep: { duration in try await sleeps.sleep(duration) }))
    signals.enteredForeground()
    await signals.foreground()
    await eventually { await transport.opened == [lea] }
    await transport.send(.subscribed)
    await eventually { sleeps.started == 1 }
    await transport.send(.subscribed)
    await eventually { sleeps.started == 2 && sleeps.cancelled == 1 }
    #expect(sleeps.cancelled == 1)
    #expect(probe.pulls == 2)
    await signals.background()
    await eventually { sleeps.cancelled == 2 }
    #expect(sleeps.cancelled == 2)
    // Aucune descente de plus : celle qui était due est annulée.
    #expect(probe.pulls == 2)
  }

  /// Mineur 3 : deux ouvertures concurrentes (premier plan et compte relu) n'ouvrent qu'une écoute.
  @Test func concurrentForegroundsOpenASingleListener() async {
    let transport = FakeTransport()
    let gate = AccountGate()
    let signals = gated(transport, gate: gate)
    let first = Task { await signals.foreground() }
    let second = Task { await signals.foreground() }
    await eventually { await gate.waiting == 2 }
    await gate.release(lea)
    await first.value
    await second.value
    #expect(signals.isOpen)
    await eventually { await transport.opened.count == 1 }
    #expect(await transport.opened == [lea])
    await signals.background()
    #expect(await transport.closes == 1)
  }

  /// Relecture Android (c) : l'écho de ma propre écriture ne déclenche pas de descente ; un autre signal, si.
  @Test func theEchoOfMyOwnWriteIsIgnored() {
    let writes = RecentItemWrites()
    let list = UUID()
    let mine = RealtimeSignal(listId: list, kind: "items")
    writes.record(listId: list, at: t0)
    #expect(writes.isEcho(mine, at: t0.addingTimeInterval(1)))
    #expect(!writes.isEcho(mine, at: t0.addingTimeInterval(RecentItemWrites.echoWindow + 0.5)))
    #expect(!writes.isEcho(RealtimeSignal(listId: UUID(), kind: "items"), at: t0.addingTimeInterval(1)))
    #expect(!writes.isEcho(RealtimeSignal(listId: list, kind: "members"), at: t0.addingTimeInterval(1)))

    let probe = SignalProbe()
    let signals = RealtimeSignals(
      transport: nil,
      dependencies: RealtimeSignals.Dependencies(
        pull: { probe.pulls += 1 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        echoDelay: { writes.echoDelay($0, at: t0.addingTimeInterval(1)) }))
    signals.handle(.signal(mine))
    signals.flush()
    #expect(probe.pulls == 0)
    signals.handle(.signal(RealtimeSignal(listId: UUID(), kind: "items")))
    signals.flush()
    #expect(probe.pulls == 1)
  }

  /// Contre-relecture de #101 (1) : un vrai signal d'un autre membre peut arriver dans la fenêtre d'un écho. Une seule
  /// descente part à la fin de la fenêtre, jamais repoussée par les échos suivants ; à la fermeture du canal, elle part
  /// aussitôt.
  @Test func anEchoDefersOnePullToTheEndOfItsWindow() async {
    let writes = RecentItemWrites()
    let list = UUID()
    writes.record(listId: list, at: t0)
    #expect(writes.echoDelay(RealtimeSignal(listId: list, kind: "items"), at: t0.addingTimeInterval(0.5)) == 1.5)
    let probe = SignalProbe()
    var waits: [Duration] = []
    let signals = RealtimeSignals(
      transport: nil,
      dependencies: RealtimeSignals.Dependencies(
        pull: { probe.pulls += 1 }, sleep: { waits.append($0) },
        echoDelay: { writes.echoDelay($0, at: t0.addingTimeInterval(0.5)) }))
    signals.handle(.signal(RealtimeSignal(listId: list, kind: "items")))
    signals.handle(.signal(RealtimeSignal(listId: list, kind: "items")))
    #expect(probe.pulls == 0)
    await eventually { probe.pulls == 1 }
    #expect(probe.pulls == 1)
    #expect(waits == [.milliseconds(1500)])

    // Fermeture avant la fin de la fenêtre : la descente reportée part tout de suite.
    let held = RealtimeSignals(
      transport: FakeTransport(),
      dependencies: RealtimeSignals.Dependencies(
        accountId: { lea }, isEmailAccount: { true }, pull: { probe.pulls += 1 },
        sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        echoDelay: { writes.echoDelay($0, at: t0.addingTimeInterval(0.5)) }))
    held.enteredForeground()
    await held.foreground()
    held.handle(.signal(RealtimeSignal(listId: list, kind: "items")))
    await held.background()
    #expect(probe.pulls == 2)
  }

  /// Contre-relecture de #101 (3) : feuille « Partager » ouverte pendant un abaissement, réseau coupé. L'erreur est
  /// captée : la feuille montre l'état hors ligne, rien ne remonte.
  @Test func theShareSheetOpenedOfflineShowsTheOfflineState() async {
    let gateway = ScriptedSyncGateway()
    await gateway.failAlways("listSharing", with: .network)
    let center = SharingCenter(
      gateway: gateway, transport: nil,
      dependencies: SharingCenter.Dependencies(isEmailAccount: { true }), monitorsNetwork: false)
    let model = center.makeShareModel(listId: UUID(), listName: "Courses de la semaine")
    await model.load()
    #expect(model.state == .offline)
    #expect(model.sharing == nil)
  }

  /// Contre-relecture de #101 (3), côté synchro : un refus (0 ligne) pendant un abaissement, puis le réseau coupé au
  /// moment de relire `list_sharing`. La passe s'arrête sans erreur, l'écriture reste en file, et la passe suivante
  /// tranche.
  @Test func aRefreshCutByTheNetworkKeepsTheWriteForTheNextPass() async throws {
    let harness = try SyncHarness()
    let me = await harness.gateway.account
    let listId = UUID()
    let itemId = UUID()
    await harness.gateway.setPull(
      lists: [ListRow(id: listId, ownerId: hadrien, name: "Partagée", createdAt: t0, updatedAt: t0)],
      items: [
        ListItemRow(
          id: itemId, listId: listId, productId: nil, label: "Lait", quantity: nil, checkedAt: nil, createdAt: t0,
          updatedAt: t0, updatedBy: hadrien)
      ])
    await harness.gateway.setMembers([
      ListMemberRow(listId: listId, userId: me, role: "editor", createdAt: t0, updatedAt: t0)
    ])
    await harness.engine.drain(pull: true)
    await harness.gateway.setReadOnlyItems([itemId])
    await harness.gateway.failAlways("listSharing", with: .network)
    try harness.lists.setChecked(itemId: itemId, checkedAt: t0, at: t0)
    await harness.engine.drain()
    #expect(try harness.fresh(OutboxEntry.self).contains { $0.entityId == itemId })

    await harness.gateway.failAlways("listSharing", with: nil)
    await harness.gateway.setMembers([
      ListMemberRow(listId: listId, userId: me, role: "viewer", createdAt: t0, updatedAt: t0)
    ])
    harness.clock.advance(3600)
    await harness.engine.drain(pull: true)
    #expect(try harness.fresh(ShoppingList.self).first { $0.id == listId }?.role == .viewer)
    #expect(try harness.fresh(OutboxEntry.self).isEmpty)
  }

  /// Relecture Android (c) : un article accepté par le serveur est noté pour son écho, par liste.
  @Test func aSentItemIsRecordedForItsEcho() async throws {
    let harness = try SyncHarness()
    let writes = RecentItemWrites()
    let clock = harness.clock
    let engine = SyncEngine(
      gateway: harness.gateway, container: harness.container, cursors: harness.cursors,
      classify: { PulledItemClassification(normalizedName: $0.lowercased(), categoryId: "other") },
      dependencies: SyncEngine.Dependencies(
        now: { clock.now }, jitter: { 1 }, isOnline: { true },
        sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        itemSent: { writes.record(listId: $0) }))
    let list = try harness.lists.createList(name: "Semaine", at: t0)
    let other = UUID()
    _ = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    await engine.drain()
    #expect(writes.isEcho(RealtimeSignal(listId: list.id, kind: "items")))
    #expect(!writes.isEcho(RealtimeSignal(listId: other, kind: "items")))
  }

  /// Mineur 5 : « Quitter la liste » depuis l'écran Liste revient à Mes listes, sans l'écran « n'est plus partagée
  /// avec vous », réservé à un retrait décidé par le propriétaire.
  @Test func leavingFromTheListScreenGoesBackWithoutTheRemovalMessage() throws {
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let context = container.mainContext
    let lists = SwiftDataListRepository(context: context)
    let categories = SwiftDataCategoryRepository(context: context)
    try categories.seedIfNeeded()
    let analyzer = try EntryAnalyzer()
    let departures = ListDepartures()
    func screen(_ listId: UUID) -> ListDetailModel {
      let model = ListDetailModel(
        listId: listId, lists: lists, products: SwiftDataProductRepository(context: context), categories: categories,
        analyzer: analyzer, accountId: { lea }, departures: departures)
      model.load()
      return model
    }
    func sharedList(_ name: String) throws -> ShoppingList {
      let list = ShoppingList(name: name, syncState: .synced, ownerId: hadrien, role: .viewer)
      context.insert(list)
      try context.save()
      return list
    }

    let left = try sharedList("Quittée")
    let leaving = screen(left.id)
    departures.record(left.id)
    try lists.forgetList(id: left.id)
    leaving.load()
    #expect(leaving.didLeave)
    #expect(!leaving.wasRemoved)

    let removed = try sharedList("Retirée")
    let removing = screen(removed.id)
    try lists.forgetList(id: removed.id)
    removing.load()
    #expect(removing.wasRemoved)
    #expect(!removing.didLeave)
  }

  /// Contre-relecture de #100 : un départ ne sert qu'une fois. Quittée, réinvitée, puis retirée par le propriétaire,
  /// la liste annonce le retrait ; de même si elle a été quittée depuis Mes listes, sans écran Liste ouvert.
  @Test func aDepartureIsConsumedSoALaterRemovalIsAnnounced() throws {
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let context = container.mainContext
    let lists = SwiftDataListRepository(context: context)
    let categories = SwiftDataCategoryRepository(context: context)
    try categories.seedIfNeeded()
    let analyzer = try EntryAnalyzer()
    let departures = ListDepartures()
    func screen(_ listId: UUID) -> ListDetailModel {
      let model = ListDetailModel(
        listId: listId, lists: lists, products: SwiftDataProductRepository(context: context), categories: categories,
        analyzer: analyzer, accountId: { lea }, departures: departures)
      model.load()
      return model
    }
    func arrive(_ id: UUID) throws {
      context.insert(ShoppingList(id: id, name: "Partagée", syncState: .synced, ownerId: hadrien, role: .editor))
      try context.save()
    }

    // Quittée depuis l'écran Liste : départ, consommé.
    let id = UUID()
    try arrive(id)
    let first = screen(id)
    departures.record(id)
    try lists.forgetList(id: id)
    first.load()
    first.load()
    #expect(first.didLeave && !first.wasRemoved)
    #expect(!departures.consume(id))
    // Réinvitée, puis retirée par le propriétaire : un retrait.
    try arrive(id)
    let second = screen(id)
    try lists.forgetList(id: id)
    second.load()
    #expect(second.wasRemoved && !second.didLeave)

    // Quittée depuis Mes listes (aucun écran Liste), réinvitée : le départ ne vaut plus dès que la liste revient.
    let other = UUID()
    departures.record(other)
    try arrive(other)
    let reopened = screen(other)
    try lists.forgetList(id: other)
    reopened.load()
    #expect(reopened.wasRemoved && !reopened.didLeave)
  }

  /// Mineur 6 : aucune invitation en attente, les deux phrases de la maquette (`inv.none`, `inv.none.body`).
  @Test func noInvitationTexts() {
    let none = SharingFormat.noInvitation(email: "lea@exemple.fr")
    #expect(none.title == "Aucune invitation n'attend lea@exemple.fr.")
    #expect(none.body == "Celle que vous avez reçue vise peut-être une autre adresse : ouvrez le lien de l'e-mail.")
    #expect(SharingFormat.noInvitation(email: nil).title == "Aucune invitation en attente.")
  }

  /// Mineur 7 : la marque d'auteur et l'avatar de la carte d'invitation grandissent avec Dynamic Type.
  @Test func authorMarkAndInvitationAvatarFollowDynamicType() throws {
    func size(_ view: some View, _ typeSize: DynamicTypeSize) throws -> CGSize {
      let renderer = ImageRenderer(content: view.environment(\.dynamicTypeSize, typeSize))
      return try #require(renderer.uiImage).size
    }
    let mark = AuthorMark(initial: "L")
    #expect(try size(mark, .large) == CGSize(width: 20, height: 20))
    #expect(try size(mark, .accessibility3).width > 20)
    let avatar = MemberAvatar(label: "H", size: 36, ring: false, scalesWithText: true)
    #expect(try size(avatar, .accessibility3).width > (try size(avatar, .large)).width)
    // Les pastilles de la barre gardent leur taille : deux pastilles recouvertes de 8 pt, une seule (le nombre) aux
    // tailles d'accessibilité.
    #expect(try size(MemberAvatar(label: "L"), .accessibility3) == CGSize(width: 28, height: 28))
    #expect(try size(BarAvatarStack(labels: ["L", "T"]), .large) == CGSize(width: 48, height: 28))
    #expect(try size(BarAvatarStack(labels: ["L", "T"]), .accessibility3) == CGSize(width: 28, height: 28))
  }

  /// Relecture Android (b) : le lien copié porte le jeton. Il reste sur l'appareil et s'efface au bout d'une heure.
  @Test func theCopiedLinkIsLocalAndExpires() throws {
    let options = SensitivePasteboard.options(now: t0)
    #expect(options[.localOnly] as? Bool == true)
    #expect(options[.expirationDate] as? Date == t0.addingTimeInterval(3600))
    let name = UIPasteboard.Name("app.parcourses.tests.\(UUID().uuidString)")
    let pasteboard = try #require(UIPasteboard(name: name, create: true))
    defer { UIPasteboard.remove(withName: name) }
    let link = "parcourses://invitation#\(UITestSharingGateway.token)"
    SensitivePasteboard.copy(link, to: pasteboard, now: .now)
    #expect(pasteboard.string == link)
  }
}
