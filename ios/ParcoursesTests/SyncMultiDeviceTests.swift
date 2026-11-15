import Foundation
import SwiftData
import Testing

@testable import Parcourses

private nonisolated let t0 = syncEpoch

private func serverList(_ id: UUID, owner: UUID, name: String, at date: Date) -> ListRow {
  ListRow(id: id, ownerId: owner, name: name, createdAt: date, updatedAt: date)
}

private func serverItem(_ id: UUID, listId: UUID, label: String, checkedAt: Date? = nil, at date: Date) -> ListItemRow {
  ListItemRow(
    id: id, listId: listId, productId: nil, label: label, quantity: nil, checkedAt: checkedAt, createdAt: date,
    updatedAt: date)
}

/// Synchro multi-appareil et partage côté moteur (#87, lot 87.3) : envoi par champ, 0 ligne, refus, réconciliation des
/// listes, pierres tombales.
@MainActor
@Suite(.serialized) struct SyncMultiDeviceTests {
  /// Liste et article envoyés une première fois, descente comprise.
  private func syncedItem(_ harness: SyncHarness) async throws -> (list: ShoppingList, item: ListItem) {
    let list = try harness.lists.createList(name: "Courses", at: t0)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    await harness.engine.drain(pull: true)
    #expect(try harness.entries().isEmpty)
    await harness.gateway.clearCalls()
    return (list, item)
  }

  private func freshItem(_ harness: SyncHarness, _ id: UUID) throws -> ListItem? {
    try harness.fresh(ListItem.self).first { $0.id == id }
  }

  @Test func anItemOnTheServerSendsOnlyItsChangedFields() async throws {
    let harness = try SyncHarness()
    let (_, item) = try await syncedItem(harness)
    #expect(try freshItem(harness, item.id)?.isOnServer == true)

    try harness.lists.setChecked(itemId: item.id, checkedAt: t0.addingTimeInterval(10), at: t0.addingTimeInterval(10))
    #expect(try harness.entries().first?.changedFields == [ListItemFields.checkedAt])
    await harness.engine.drain()
    let calls = await harness.gateway.calls
    #expect(calls.contains("updateItem") && !calls.contains("insertItem"))
    #expect(await harness.gateway.patches.last?.columns == [ListItemFields.checkedAt])
  }

  /// Insertion arrivée mais réponse perdue : l'article n'est pas accusé, puis il est coché. L'insertion suivante ne
  /// touche rien ; les champs de l'entrée partent en mise à jour, la coche arrive.
  @Test func aChangeAfterAnInsertWhoseResponseWasLostReachesTheServer() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    await harness.gateway.setLosesInsertResponses(true)
    await harness.engine.drain()
    #expect(try freshItem(harness, item.id)?.isOnServer == false)
    let checkedAt = t0.addingTimeInterval(30)
    try harness.lists.setChecked(itemId: item.id, checkedAt: checkedAt, at: checkedAt)
    await harness.skipBackoff()
    await harness.gateway.clearCalls()
    await harness.engine.drain()
    let calls = await harness.gateway.calls
    let insert = try #require(calls.firstIndex(of: "insertItem"))
    let update = try #require(calls.firstIndex(of: "updateItem"))
    #expect(insert < update)
    #expect(await harness.gateway.patches.last?.columns.contains(ListItemFields.checkedAt) == true)
    #expect(await harness.gateway.savedItems.last?.checkedAt == checkedAt)
    #expect(try harness.entries().isEmpty)
    #expect(try freshItem(harness, item.id)?.isOnServer == true)
  }

  /// Insertion ignorée d'un article enterré : la mise à jour qui suit ne touche rien, la pierre tombale tranche.
  @Test func anIgnoredInsertOfABuriedItemDropsIt() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    await harness.engine.drain()
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    await harness.gateway.deleteElsewhere(item.id, listId: list.id, at: t0)
    await harness.engine.drain()
    #expect(try freshItem(harness, item.id) == nil)
    #expect(try harness.entries().isEmpty)
    #expect(await harness.gateway.calls.contains("fetchTombstones(ids:)"))
  }

  /// `refreshAccess` sur une liste à soi : un article jamais envoyé et son entrée restent.
  @Test func reloadingOwnListKeepsUnsentItems() async throws {
    let harness = try SyncHarness()
    let (list, item) = try await syncedItem(harness)
    await harness.gateway.setPull(items: [serverItem(item.id, listId: list.id, label: "Lait", at: t0)])
    // L'article ajouté attend (23503, mis de côté sans arrêter la passe).
    await harness.gateway.fail("insertItem", with: [.dependencyMissing(code: "23503")])
    let unsent = try harness.lists.addItem(
      listId: list.id, label: "Pain", normalizedName: "pain", quantity: nil, productId: nil, categoryId: "bakery",
      at: t0)
    await harness.engine.drain()
    try await harness.engine.refreshAccess(listId: list.id)
    #expect(try freshItem(harness, unsent.id) != nil)
    #expect(try harness.entries().map(\.entityId) == [unsent.id])
    #expect(try freshItem(harness, item.id) != nil)
  }

  /// Vecteur `003` (format 2) : sur ma liste, 0 ligne sans pierre tombale (purgée) = supprimé ailleurs. Seule cette
  /// entrée part ; celle d'un autre article reste.
  @Test func anUntouchedUpdateOnMyListWithoutTombstoneDropsOnlyThatItem() async throws {
    let harness = try SyncHarness()
    let (list, item) = try await syncedItem(harness)
    await harness.gateway.setReadOnlyItems([item.id])
    await harness.gateway.fail("insertItem", with: [.dependencyMissing(code: "23503")])
    let other = try harness.lists.addItem(
      listId: list.id, label: "Pain", normalizedName: "pain", quantity: nil, productId: nil, categoryId: "bakery",
      at: t0)
    try harness.lists.setChecked(itemId: item.id, checkedAt: t0, at: t0)
    await harness.engine.drain()
    #expect(try freshItem(harness, item.id) == nil)
    #expect(try freshItem(harness, other.id) != nil)
    #expect(try harness.entries().map(\.entityId) == [other.id])
    #expect(await !harness.gateway.calls.contains("accessibleListIds"))
  }

  /// Vecteur `002` : une entrée remplacée avant l'envoi garde sa place et l'union des champs.
  @Test func aReplacedEntryKeepsItsSequenceAndTheUnionOfFields() async throws {
    let harness = try SyncHarness()
    let (_, item) = try await syncedItem(harness)
    harness.online.isOn = false
    try harness.lists.setChecked(itemId: item.id, checkedAt: t0, at: t0)
    let sequence = try #require(try harness.entries().first?.sequence)
    item.quantity = "2"
    try harness.context.enqueueUpsert(of: item, at: t0, changedFields: [ListItemFields.quantity])
    try harness.context.save()
    let entries = try harness.entries()
    #expect(entries.count == 1)
    #expect(entries.first?.sequence == sequence)
    #expect(entries.first?.changedFields == [ListItemFields.checkedAt, ListItemFields.quantity])
  }

  /// Vecteur `003`, pierre tombale : supprimé ailleurs, l'article et son entrée partent sans réessai ni réinsertion.
  @Test func anUntouchedUpdateWithATombstoneDropsTheItem() async throws {
    let harness = try SyncHarness()
    let (list, item) = try await syncedItem(harness)
    await harness.gateway.deleteElsewhere(item.id, listId: list.id, at: t0)
    try harness.lists.setChecked(itemId: item.id, checkedAt: t0, at: t0)
    await harness.engine.drain()
    #expect(try freshItem(harness, item.id) == nil)
    #expect(try harness.entries().isEmpty)
    let calls = await harness.gateway.calls
    #expect(calls.contains("fetchTombstones(ids:)"))
    #expect(!calls.contains("insertItem"))
  }

  /// Vecteur `003`, sans pierre tombale : rôle abaissé. La liste est rechargée, la valeur du serveur revient.
  @Test func anUntouchedUpdateWithoutTombstoneReloadsTheList() async throws {
    let harness = try SyncHarness()
    let (list, item) = try await syncedItem(harness)
    await harness.gateway.setReadOnlyItems([item.id])
    // La liste est celle d'un autre (descendue avec son propriétaire) : 0 ligne sans pierre tombale = accès perdu.
    await harness.gateway.setPull(
      lists: [serverList(list.id, owner: UUID(), name: "Courses", at: t0)],
      items: [serverItem(item.id, listId: list.id, label: "Lait demi-écrémé", at: t0)])
    harness.clock.advance(120)
    await harness.engine.drain(pull: true)
    await harness.gateway.clearCalls()
    try harness.lists.setChecked(itemId: item.id, checkedAt: t0, at: t0)
    await harness.engine.drain()
    let local = try #require(try freshItem(harness, item.id))
    #expect(local.checkedAt == nil)
    #expect(local.label == "Lait demi-écrémé")
    #expect(try harness.entries().isEmpty)
    let calls = await harness.gateway.calls
    #expect(calls.contains("accessibleListIds") && calls.contains("fetchItems(listId:)"))
  }

  /// Vecteur `004` : un ajout refusé dans la liste d'un autre (rôle abaissé) recharge la liste, sans abandon en file.
  @Test func aRefusedInsertIntoSomeoneElsesListReloadsIt() async throws {
    let harness = try SyncHarness()
    let listId = UUID()
    let kept = UUID()
    await harness.gateway.setPull(
      lists: [serverList(listId, owner: UUID(), name: "Partagée", at: t0)],
      items: [serverItem(kept, listId: listId, label: "Pain", at: t0)])
    await harness.engine.drain(pull: true)
    #expect(try harness.fresh(ShoppingList.self).first?.ownerId != nil)
    await harness.gateway.setRefusedLists([listId])
    let added = try harness.lists.addItem(
      listId: listId, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0)
    await harness.engine.drain()
    #expect(try freshItem(harness, added.id) == nil)
    #expect(try freshItem(harness, kept) != nil)
    #expect(try harness.entries().isEmpty)
  }

  /// Vecteur `005` : une liste synchronisée qui n'est plus accessible quitte l'appareil avec ses articles.
  @Test func aListGoneFromTheServerLeavesTheDevice() async throws {
    let harness = try SyncHarness()
    let (list, item) = try await syncedItem(harness)
    let other = try harness.lists.createList(name: "Autre", at: t0)
    await harness.gateway.setHiddenLists([list.id])
    await harness.engine.drain(pull: true)
    let lists = try harness.fresh(ShoppingList.self)
    #expect(lists.map(\.id) == [other.id])
    #expect(try freshItem(harness, item.id) == nil)
    #expect(try harness.entries().isEmpty)
  }

  /// Vecteur `005` : une liste nouvellement accessible descend entièrement, curseurs ignorés.
  @Test func aNewlyAccessibleListIsFetchedFully() async throws {
    let harness = try SyncHarness()
    let first = UUID()
    let me = await harness.gateway.account
    await harness.gateway.setPull(lists: [serverList(first, owner: me, name: "Mienne", at: t0.addingTimeInterval(100))])
    await harness.engine.drain(pull: true)
    let shared = UUID()
    let sharedItem = UUID()
    await harness.gateway.setPull(
      lists: [
        serverList(first, owner: me, name: "Mienne", at: t0.addingTimeInterval(100)),
        serverList(shared, owner: UUID(), name: "Partagée", at: t0),
      ],
      items: [serverItem(sharedItem, listId: shared, label: "Café", at: t0)])
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.listCursors.last == .some(nil))
    #expect(await harness.gateway.calls.contains("fetchItems(listId:)"))
    #expect(try harness.fresh(ShoppingList.self).contains { $0.id == shared })
    let item = try #require(try freshItem(harness, sharedItem))
    #expect(item.isOnServer)
  }

  /// Vecteurs `006` et `007` : pierres tombales depuis le curseur, qui avance.
  @Test func tombstonesFromTheCursorDeleteLocalItems() async throws {
    let harness = try SyncHarness()
    let (list, item) = try await syncedItem(harness)
    let cursor = try #require(harness.cursors.tombstones)
    let deletedAt = cursor.addingTimeInterval(10)
    await harness.gateway.deleteElsewhere(item.id, listId: list.id, at: deletedAt)
    harness.clock.advance(120)
    await harness.engine.drain(pull: true)
    #expect(try freshItem(harness, item.id) == nil)
    #expect(await harness.gateway.tombstoneCursors.last == .some(cursor))
    #expect(harness.cursors.tombstones == deletedAt)
  }

  /// Vecteur `007` : curseur de plus de 29 jours, réconciliation complète ; un article jamais envoyé reste.
  @Test func anOldCursorReconcilesItemsFully() async throws {
    let harness = try SyncHarness()
    let (list, item) = try await syncedItem(harness)
    await harness.gateway.purgeElsewhere(item.id)
    harness.cursors.tombstones = harness.clock.now.addingTimeInterval(-30 * 86_400)
    await harness.gateway.fail("insertItem", with: [.network])
    let unsent = try harness.lists.addItem(
      listId: list.id, label: "Pain", normalizedName: "pain", quantity: nil, productId: nil, categoryId: "bakery",
      at: t0)
    // Premier passage : l'envoi échoue, la descente attend. Le délai passé, l'article part puis la descente réconcilie.
    await harness.engine.drain(pull: true)
    #expect(try freshItem(harness, unsent.id)?.isOnServer == false)
    await harness.skipBackoff()
    await harness.engine.drain(pull: true)
    #expect(try freshItem(harness, item.id) == nil)
    #expect(try freshItem(harness, unsent.id) != nil)
    #expect(await harness.gateway.calls.contains("fetchItemIds"))
    #expect(harness.cursors.tombstones == (await harness.gateway.serverNow))
  }

  /// La descente pose les deux dates du serveur : la liste « Courses » jamais modifiée, accusée puis descendue, n'est
  /// pas renvoyée au compte suivant (vecteur `008`, règle `skip`).
  @Test func aPulledUntouchedListKeepsServerDatesAndIsNotResent() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    await harness.engine.drain()
    let owner = await harness.gateway.account
    let serverTime = t0.addingTimeInterval(500)
    await harness.gateway.setPull(lists: [serverList(list.id, owner: owner, name: "Courses", at: serverTime)])
    await harness.engine.drain(pull: true)
    let pulled = try #require(try harness.fresh(ShoppingList.self).first)
    #expect(pulled.createdAt == serverTime && pulled.updatedAt == serverTime)
    await harness.gateway.setPull()
    await harness.gateway.loseAccount()
    await harness.engine.drain(pull: true)
    #expect(try harness.fresh(ShoppingList.self).isEmpty)
  }

  @Test func deletingAnItemNeverReceivedIsNotARefusal() async throws {
    let harness = try SyncHarness()
    harness.online.isOn = false
    let list = try harness.lists.createList(name: "Courses", at: t0)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    try harness.lists.deleteItem(id: item.id)
    harness.online.isOn = true
    await harness.engine.drain()
    #expect(try harness.entries().isEmpty)
    let calls = await harness.gateway.calls
    #expect(calls.contains("deleteItem") && !calls.contains("fetchTombstones(ids:)"))
  }

  /// Entrée écrite avant 87.3 (sans champs) : toute la ligne part, puis l'insertion si 0 ligne.
  @Test func aLegacyEntrySendsTheWholeRowThenInserts() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    await harness.engine.drain()
    let item = ListItem(listId: list.id, label: "Lait", normalizedName: "lait", categoryId: "dairy", position: 0)
    harness.context.insert(item)
    let row = ListItemUpsert(
      id: item.id, listId: list.id, productId: nil, label: "Lait", quantity: nil, checkedAt: nil)
    try harness.context.enqueueOutboxEntry(
      kind: .upsertItem, entityId: item.id, payload: OutboxCoding.encode(row), at: t0)
    try harness.context.save()
    await harness.gateway.clearCalls()
    await harness.engine.drain()
    let calls = await harness.gateway.calls
    let update = try #require(calls.firstIndex(of: "updateItem"))
    let insert = try #require(calls.firstIndex(of: "insertItem"))
    #expect(update < insert)
    #expect(try freshItem(harness, item.id)?.isOnServer == true)
  }
}

/// Règles de la reprise de compte (#87 §2.3, vecteur `008`).
@MainActor
@Suite struct AccountRekeyRulesTests {
  @Test func onlyOwnModifiedListsAreResentAndUnpublishedProductsAreDropped() throws {
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let context = container.mainContext
    let (me, other) = (UUID(), UUID())
    let (published, gone) = (UUID(), UUID())
    context.insert(Product(id: published, name: "Lait", normalizedName: "lait", categoryId: "dairy"))
    let mine = ShoppingList(
      name: "À moi", createdAt: t0, updatedAt: t0.addingTimeInterval(1), syncState: .synced, ownerId: me)
    let theirs = ShoppingList(name: "D'autrui", createdAt: t0, updatedAt: t0.addingTimeInterval(1), ownerId: other)
    let empty = ShoppingList(name: "Courses", createdAt: t0, updatedAt: t0)
    let neverPulled = ShoppingList(name: "Hors ligne", createdAt: t0, updatedAt: t0)
    for list in [mine, theirs, empty, neverPulled] { context.insert(list) }
    let kept = ListItem(
      listId: mine.id, label: "Lait", normalizedName: "lait", productId: published, categoryId: "dairy", position: 0,
      syncState: .synced, isOnServer: true, updatedBy: other)
    let purged = ListItem(
      listId: mine.id, label: "Fromage", normalizedName: "fromage", productId: gone, categoryId: "dairy", position: 1,
      syncState: .synced, isOnServer: true)
    let foreign = ListItem(listId: theirs.id, label: "Pain", normalizedName: "pain", categoryId: "bakery", position: 0)
    let offline = ListItem(
      listId: neverPulled.id, label: "Café", normalizedName: "cafe", categoryId: "other", position: 0)
    for item in [kept, purged, foreign, offline] { context.insert(item) }
    try context.save()

    #expect(try AccountRekey.resendCount(in: context, previousAccountId: me) == 2)
    let oldKept = kept.id
    let remap = try AccountRekey.run(in: context, previousAccountId: me, now: t0)

    let lists = try context.fetch(FetchDescriptor<ShoppingList>())
    #expect(Set(lists.map(\.name)) == ["À moi", "Hors ligne"])
    #expect(lists.allSatisfy { $0.ownerId == nil && $0.syncState == .pending })
    let items = try context.fetch(FetchDescriptor<ListItem>())
    #expect(Set(items.map(\.label)) == ["Lait", "Fromage", "Café"])
    #expect(items.allSatisfy { !$0.isOnServer && $0.updatedBy == nil })
    #expect(items.first { $0.label == "Lait" }?.productId == published)
    #expect(items.first { $0.label == "Fromage" }?.productId == nil)
    #expect(remap[oldKept] == kept.id && kept.id != oldKept)
    let entries = try context.fetch(FetchDescriptor<OutboxEntry>())
    #expect(entries.filter { $0.kind == .upsertList }.count == 2)
    #expect(entries.filter { $0.kind == .upsertItem }.allSatisfy { $0.changedFields == ListItemFields.all })
  }

  /// Ancien compte inconnu : une liste au propriétaire connu ne peut pas être prouvée à soi.
  @Test func withoutThePreviousAccountAKnownOwnerIsNotResent() throws {
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let context = container.mainContext
    context.insert(ShoppingList(name: "Descendue", createdAt: t0, updatedAt: t0.addingTimeInterval(1), ownerId: UUID()))
    context.insert(ShoppingList(name: "Locale", createdAt: t0, updatedAt: t0.addingTimeInterval(1)))
    try context.save()
    _ = try AccountRekey.run(in: context, previousAccountId: nil, now: t0)
    #expect(try context.fetch(FetchDescriptor<ShoppingList>()).map(\.name) == ["Locale"])
  }
}

/// Vecteur `009` côté passerelle : un compte e-mail sans session n'en recrée jamais d'anonyme, sans même appeler le
/// serveur.
@Suite struct SessionLossGatewayTests {
  @Test func anEmailAccountWithoutSessionWaitsInsteadOfCreatingAnAnonymousOne() async throws {
    let configuration = try #require(SupabaseConfiguration(url: "http://127.0.0.1:9", publishableKey: "k"))
    let defaults = try #require(UserDefaults(suiteName: "tests.session-loss.\(UUID().uuidString)"))
    let kinds = MemoryAccountKindStore(.email)
    let gateway = SupabaseGateway(
      configuration: configuration, store: MemorySecureStore(),
      deletionFlags: UserDefaultsAccountDeletionFlagStore(defaults: defaults), accountKinds: kinds)
    await #expect(throws: RemoteError.unauthorized) { try await gateway.ensureSession() }
    #expect(try await gateway.accountEmail() == nil)
    // Compte anonyme : la création est tentée (serveur injoignable ici).
    kinds.save(.anonymous)
    await #expect(throws: RemoteError.network) { try await gateway.ensureSession() }
  }
}

/// README des vecteurs : curseur des pierres tombales trop vieux, la réconciliation complète passe avant l'envoi.
@MainActor
@Suite(.serialized) struct StaleTombstoneCursorTests {
  @Test func aStaleCursorReconcilesItemsBeforeSendingTheQueue() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    await harness.engine.drain(pull: true)
    // Supprimé ailleurs il y a plus de 30 jours (pierre tombale purgée), puis modifié ici après une longue absence.
    await harness.gateway.purgeElsewhere(item.id)
    harness.clock.advance(40 * 86_400)
    try harness.lists.setChecked(itemId: item.id, checkedAt: harness.clock.now, at: harness.clock.now)
    await harness.gateway.clearCalls()
    await harness.engine.drain()
    let calls = await harness.gateway.calls
    #expect(calls.contains("fetchItemIds"))
    #expect(!calls.contains("updateItem") && !calls.contains("insertItem"))
    #expect(try harness.fresh(ListItem.self).isEmpty)
    #expect(try harness.entries().isEmpty)
  }
}

/// Sans heure du serveur, le curseur des pierres tombales reste vide : la réconciliation complète avant l'envoi n'a lieu
/// qu'une fois par heure, et une seule fois par passe (la descente ne la refait pas).
@MainActor
@Suite(.serialized) struct UndatedFullReconcileTests {
  private func serverDates(_ harness: SyncHarness) async -> Int {
    await harness.gateway.calls.filter { $0 == "serverDate" }.count
  }

  @Test func withoutServerDateFullReconciliationIsSpacedAndDoneOncePerPass() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    await harness.engine.drain(pull: true)
    await harness.gateway.setServerNow(nil)
    harness.cursors.tombstones = nil
    await harness.gateway.clearCalls()
    // Avant l'envoi, puis pas une seconde fois dans la descente de la même passe.
    await harness.engine.drain(pull: true)
    #expect(await serverDates(harness) == 1)
    #expect(harness.cursors.tombstones == nil)

    // Dans l'heure : l'envoi part sans réconciliation.
    await harness.gateway.clearCalls()
    harness.clock.advance(10)
    try harness.lists.setChecked(itemId: item.id, checkedAt: harness.clock.now, at: harness.clock.now)
    await harness.engine.drain()
    #expect(await harness.gateway.calls.contains("updateItem"))
    #expect(await serverDates(harness) == 0)

    // Une heure plus tard : de nouveau avant l'envoi.
    await harness.gateway.clearCalls()
    harness.clock.advance(SyncRetryPolicy.undatedFullReconcileSpacing)
    try harness.lists.setChecked(itemId: item.id, checkedAt: nil, at: harness.clock.now)
    await harness.engine.drain()
    let calls = await harness.gateway.calls
    let reconciled = try #require(calls.firstIndex(of: "serverDate"))
    let sent = try #require(calls.firstIndex(of: "updateItem"))
    #expect(reconciled < sent)
    #expect(calls.filter { $0 == "serverDate" }.count == 1)
  }
}

/// README des vecteurs : un ancien compte e-mail n'est jamais repris, même si l'app est tuée entre `verifyCode` et la
/// purge du changement de compte.
@MainActor
@Suite(.serialized) struct EmailAccountRekeyTests {
  @Test func listsOfAPreviousEmailAccountNeverReachTheNextAccount() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses de A", at: t0)
    try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    try harness.lists.renameList(id: list.id, name: "Courses de A, renommée", at: t0.addingTimeInterval(1))
    harness.online.isOn = false
    await harness.engine.drain()
    harness.online.isOn = true
    // Les curseurs sont ceux du compte e-mail A, la session celle de B : l'app a été tuée avant la purge.
    harness.cursors.accountId = UUID()
    harness.cursors.accountKind = .email
    await harness.gateway.loseAccount()
    let engine = harness.makeEngine()
    await engine.drain(pull: true)
    #expect(await harness.gateway.savedLists.isEmpty)
    #expect(await harness.gateway.savedItems.isEmpty)
    #expect(try harness.fresh(ShoppingList.self).isEmpty)
    #expect(try harness.entries().isEmpty)
  }

  /// Ancien compte anonyme : repris comme avant.
  @Test func listsOfAPreviousAnonymousAccountAreResent() async throws {
    let harness = try SyncHarness()
    let list = try harness.modifiedList("Courses")
    _ = list
    harness.online.isOn = false
    await harness.engine.drain()
    harness.online.isOn = true
    harness.cursors.accountId = UUID()
    harness.cursors.accountKind = .anonymous
    await harness.gateway.loseAccount()
    await harness.makeEngine().drain(pull: true)
    #expect(await harness.gateway.savedLists.count == 1)
  }
}

@Suite struct KeptTokenTests {
  /// Un rafraîchissement en échec ne fait pas échouer le code : aucun jeton gardé.
  @Test func aFailedRefreshKeepsNoTokenWithoutFailing() async {
    let id = UUID()
    let failed = await SupabaseGateway.anonymousSessionToKeep(
      accountId: id, isAnonymous: true, accessToken: "vieux", expiresAt: 1000, now: 1000,
      refresh: { throw RemoteError.network })
    #expect(failed == nil)
    let refreshed = await SupabaseGateway.anonymousSessionToKeep(
      accountId: id, isAnonymous: true, accessToken: "vieux", expiresAt: 1000, now: 1000, refresh: { "neuf" })
    #expect(refreshed == SupabaseGateway.KeptAnonymousSession(accountId: id, accessToken: "neuf"))
    let fresh = await SupabaseGateway.anonymousSessionToKeep(
      accountId: id, isAnonymous: true, accessToken: "valable", expiresAt: 5000, now: 1000,
      refresh: {
        Issue.record("rafraîchissement inutile")
        return "neuf"
      })
    #expect(fresh?.accessToken == "valable")
    let email = await SupabaseGateway.anonymousSessionToKeep(
      accountId: id, isAnonymous: false, accessToken: "jeton", expiresAt: 5000, now: 1000, refresh: { "neuf" })
    #expect(email == nil)
  }

  @Test func anAnonymousTokenCloseToExpiryIsRefreshedBeforeBeingKept() {
    #expect(SupabaseGateway.needsRefreshBeforeKeeping(expiresAt: 1000, now: 1000))
    #expect(SupabaseGateway.needsRefreshBeforeKeeping(expiresAt: 1000 + 599, now: 1000))
    #expect(!SupabaseGateway.needsRefreshBeforeKeeping(expiresAt: 1000 + 600, now: 1000))
  }
}
