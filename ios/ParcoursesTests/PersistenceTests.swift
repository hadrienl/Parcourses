import Domain
import Foundation
import SwiftData
import Testing

@testable import Parcourses

private func makeContext() throws -> ModelContext {
  ModelContext(try PersistenceStack.makeContainer(storage: .inMemory))
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
@Suite struct SchemaTests {
  /// Garde-fou : ces noms sont repris tels quels par Android. Un écart doit passer par `SYNC.md`.
  @Test func entityAndPropertyNamesMatchTheDesign() {
    let expected: [String: Set<String>] = [
      "ShoppingList": ["id", "name", "createdAt", "updatedAt", "deletedAt", "syncStateRaw"],
      "ListItem": [
        "id", "listId", "label", "normalizedName", "quantity", "productId", "categoryId", "checkedAt", "notFoundAt",
        "position", "updatedAt", "syncStateRaw",
      ],
      "Visit": ["id", "storeId", "listId", "listWasSorted", "startedAt", "endedAt", "syncStateRaw", "endSyncStateRaw"],
      "Check": ["id", "visitId", "itemId", "productId", "categoryId", "checkedAt", "syncStateRaw"],
      "Store": ["id", "name", "chain", "address", "lastDistanceM", "lastUsedAt"],
      "GraphSnapshot": ["storeId", "snapshotVersion", "paramsVersion", "confidenceQ", "fetchedAt", "payload"],
      "Product": ["id", "name", "normalizedName", "categoryId"],
      "Category": ["id", "slug", "rank", "label"],
      "CategorySeedState": ["id", "version"],
      "OutboxEntry": [
        "id", "sequence", "kindRaw", "entityId", "payload", "createdAt", "attempts", "nextAttemptAt", "lastError",
        "syncStateRaw",
      ],
    ]
    let schema = Schema(versionedSchema: SchemaV1.self)
    let actual = Dictionary(
      uniqueKeysWithValues: schema.entities.map { ($0.name, Set($0.storedProperties.map(\.name))) })
    #expect(actual == expected)
  }

  @Test func migrationPlanStartsAtV1() {
    #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    #expect(ParcoursesMigrationPlan.schemas.count == 1)
  }

  @Test func valuesSurviveReopeningTheStoreFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "test.store")
    let (entryId, storeId) = (UUID(), UUID())
    // Au-delà de 2^53 : une perte de précision (Double) se verrait.
    let bigVersion = Int64(1) << 60 + 1
    let payload = Data([0, 255, 7])

    do {
      let context = ModelContext(try PersistenceStack.makeContainer(storage: .file(url)))
      context.insert(ShoppingList(name: "Samedi", syncState: .failed))
      context.insert(
        OutboxEntry(id: entryId, sequence: bigVersion, kind: .closeVisit, entityId: UUID(), payload: payload))
      context.insert(
        GraphSnapshot(storeId: storeId, snapshotVersion: bigVersion, paramsVersion: 2, confidenceQ: 3, payload: payload)
      )
      try context.save()
    }

    let context = ModelContext(try PersistenceStack.makeContainer(storage: .file(url)))
    #expect(try context.fetch(FetchDescriptor<ShoppingList>()).first?.syncState == .failed)
    let entry = try #require(try context.fetch(FetchDescriptor<OutboxEntry>()).first)
    #expect(entry.kind == .closeVisit)
    #expect(entry.sequence == bigVersion)
    #expect(entry.payload == payload)
    let snapshot = try #require(try context.fetch(FetchDescriptor<GraphSnapshot>()).first)
    #expect(snapshot.snapshotVersion == bigVersion)
    #expect(snapshot.payload == payload)

    // #Unique s'applique encore après réouverture.
    context.insert(OutboxEntry(id: entryId, sequence: 9, kind: .deleteList, entityId: UUID(), payload: Data()))
    try context.save()
    let entries = try context.fetch(FetchDescriptor<OutboxEntry>())
    #expect(entries.count == 1)
    #expect(entries.first?.kind == .deleteList)
  }

  @Test func missingAppGroupThrowsInsteadOfCrashing() {
    #expect(throws: PersistenceError.appGroupUnavailable("group.absent")) {
      _ = try PersistenceStack.makeContainer(storage: .appGroup("group.absent"), groupContainerURL: { _ in nil })
    }
  }

  @Test func predicatesOnRawEnumsWork() throws {
    let context = try makeContext()
    context.insert(ShoppingList(name: "A", syncState: .pending))
    context.insert(ShoppingList(name: "B", syncState: .synced))
    context.insert(OutboxEntry(sequence: 1, kind: .upsertItem, entityId: UUID(), payload: Data(), syncState: .failed))
    try context.save()

    let pending = SyncState.pending.rawValue
    let failed = SyncState.failed.rawValue
    let kind = OutboxKind.upsertItem.rawValue
    let lists = try context.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.syncStateRaw == pending }))
    #expect(lists.map(\.name) == ["A"])
    let entries = FetchDescriptor<OutboxEntry>(
      predicate: #Predicate { $0.kindRaw == kind && $0.syncStateRaw == failed })
    #expect(try context.fetchCount(entries) == 1)
  }

  @Test func commitRollsBackWhenSaveFails() throws {
    struct SaveFailure: Error {}
    let context = try makeContext()
    context.insert(ShoppingList(name: "Gardée"))
    try context.save()
    context.insert(ShoppingList(name: "Annulée"))

    #expect(throws: SaveFailure.self) { try context.commit(using: { throw SaveFailure() }) }
    #expect(!context.hasChanges)
    #expect(try context.fetch(FetchDescriptor<ShoppingList>()).map(\.name) == ["Gardée"])
  }

  @Test func enumsRoundTrip() throws {
    let context = try makeContext()
    context.insert(OutboxEntry(sequence: 1, kind: .insertChecks, entityId: UUID(), payload: Data([1])))
    context.insert(ShoppingList(name: "L", syncState: .failed))
    try context.save()
    #expect(try context.fetch(FetchDescriptor<OutboxEntry>()).first?.kind == .insertChecks)
    #expect(try context.fetch(FetchDescriptor<ShoppingList>()).first?.syncState == .failed)
  }

  @Test func uniqueIdUpsertsInsteadOfDuplicating() throws {
    let context = try makeContext()
    let id = UUID()
    context.insert(Product(id: id, name: "Lait", normalizedName: "lait"))
    try context.save()
    context.insert(Product(id: id, name: "Lait demi", normalizedName: "lait demi"))
    try context.save()
    let products = try context.fetch(FetchDescriptor<Product>())
    #expect(products.count == 1)
    #expect(products.first?.name == "Lait demi")
  }
}

@MainActor
@Suite struct OutboxTests {
  @Test func sequenceIncreasesWithinASingleTransaction() throws {
    let context = try makeContext()
    let first = try context.enqueueOutboxEntry(kind: .upsertList, entityId: UUID(), payload: Data(), at: t0)
    // Date antérieure : seul `sequence` fait foi.
    let second = try context.enqueueOutboxEntry(
      kind: .upsertItem, entityId: UUID(), payload: Data(), at: t0.addingTimeInterval(-60))
    try context.save()
    let third = try context.enqueueOutboxEntry(kind: .deleteItem, entityId: UUID(), payload: Data(), at: t0)

    #expect([first.sequence, second.sequence, third.sequence] == [1, 2, 3])
  }
}

@MainActor
@Suite struct ListRepositoryTests {
  private func addItem(_ repository: SwiftDataListRepository, listId: UUID, label: String) throws -> ListItem {
    try repository.addItem(
      listId: listId, label: label, normalizedName: label, quantity: nil, productId: nil, categoryId: "other", at: t0)
  }

  @Test func listsAreSortedByMostRecentAndHideDeleted() throws {
    let repository = SwiftDataListRepository(context: try makeContext())
    let old = try repository.createList(name: "Ancienne", at: t0)
    let recent = try repository.createList(name: "Récente", at: t0.addingTimeInterval(10))
    let deleted = try repository.createList(name: "Supprimée", at: t0.addingTimeInterval(20))
    try repository.deleteList(id: deleted.id, at: t0.addingTimeInterval(30))

    #expect(try repository.lists().map(\.id) == [recent.id, old.id])
    #expect(try repository.list(id: deleted.id) == nil)
    #expect(deleted.deletedAt != nil)
  }

  @Test func renameMarksPendingAgain() throws {
    let repository = SwiftDataListRepository(context: try makeContext())
    let list = try repository.createList(name: "A", at: t0)
    list.syncState = .synced
    try repository.renameList(id: list.id, name: "B", at: t0.addingTimeInterval(1))
    #expect(list.name == "B")
    #expect(list.syncState == .pending)
    #expect(list.updatedAt == t0.addingTimeInterval(1))
  }

  @Test func itemsGetIncreasingPositionsPerList() throws {
    let repository = SwiftDataListRepository(context: try makeContext())
    let first = try repository.createList(name: "1", at: t0)
    let second = try repository.createList(name: "2", at: t0)
    _ = try addItem(repository, listId: first.id, label: "a")
    _ = try addItem(repository, listId: first.id, label: "b")
    let other = try addItem(repository, listId: second.id, label: "c")

    #expect(try repository.items(listId: first.id).map(\.label) == ["a", "b"])
    #expect(try repository.items(listId: first.id).map(\.position) == [0, 1])
    #expect(other.position == 0)
  }

  @Test func addItemToAnUnknownListFails() throws {
    let repository = SwiftDataListRepository(context: try makeContext())
    let id = UUID()
    #expect(throws: RepositoryError.notFound(id)) {
      _ = try addItem(repository, listId: id, label: "a")
    }
  }

  @Test func checkingIsSynchronizedButNotFoundIsLocal() throws {
    let repository = SwiftDataListRepository(context: try makeContext())
    let list = try repository.createList(name: "L", at: t0)
    let item = try addItem(repository, listId: list.id, label: "a")

    item.syncState = .synced
    try repository.setNotFound(itemId: item.id, notFoundAt: t0, at: t0)
    #expect(item.notFoundAt == t0)
    #expect(item.syncState == .synced)

    try repository.setChecked(itemId: item.id, checkedAt: t0, at: t0)
    #expect(item.checkedAt == t0)
    #expect(item.syncState == .pending)

    try repository.setChecked(itemId: item.id, checkedAt: nil, at: t0)
    #expect(item.checkedAt == nil)
  }

  @Test func deletedListRefusesWritesAndReadsEmpty() throws {
    let repository = SwiftDataListRepository(context: try makeContext())
    let list = try repository.createList(name: "L", at: t0)
    let item = try addItem(repository, listId: list.id, label: "a")
    let (listId, itemId) = (list.id, item.id)
    try repository.deleteList(id: listId, at: t0)
    let refused = RepositoryError.listDeleted(listId)

    #expect(try repository.items(listId: listId).isEmpty)
    #expect(throws: refused) { _ = try addItem(repository, listId: listId, label: "b") }
    #expect(throws: refused) { try repository.renameList(id: listId, name: "M", at: t0) }
    #expect(throws: refused) { try repository.deleteList(id: listId, at: t0) }
    #expect(throws: refused) { try repository.setChecked(itemId: itemId, checkedAt: t0, at: t0) }
    #expect(throws: refused) { try repository.setNotFound(itemId: itemId, notFoundAt: t0, at: t0) }
    #expect(throws: refused) { try repository.deleteItem(id: itemId) }
  }

  @Test func deleteItemRemovesIt() throws {
    let repository = SwiftDataListRepository(context: try makeContext())
    let list = try repository.createList(name: "L", at: t0)
    let item = try addItem(repository, listId: list.id, label: "a")
    let id = item.id
    try repository.deleteItem(id: id)
    #expect(try repository.items(listId: list.id).isEmpty)
    #expect(throws: RepositoryError.notFound(id)) { try repository.deleteItem(id: id) }
  }
}

@MainActor
@Suite struct StoreRepositoryTests {
  @Test func upsertKeepsUsageAndRecentIsOrdered() throws {
    let repository = SwiftDataStoreRepository(context: try makeContext())
    let (a, b, unused) = (UUID(), UUID(), UUID())
    for id in [a, b, unused] {
      try repository.upsertStore(id: id, name: "M", chain: nil, address: nil, lastDistanceM: 10)
    }
    try repository.markUsed(id: a, at: t0)
    try repository.markUsed(id: b, at: t0.addingTimeInterval(1))
    try repository.upsertStore(id: a, name: "Renommé", chain: "C", address: nil, lastDistanceM: 5)

    #expect(try repository.recentStores(limit: 5).map(\.id) == [b, a])
    #expect(try repository.recentStores(limit: 1).map(\.id) == [b])
    #expect(try repository.store(id: a)?.name == "Renommé")
    #expect(try repository.store(id: a)?.lastUsedAt == t0)
  }

  @Test func markUsedOnUnknownStoreFails() throws {
    let repository = SwiftDataStoreRepository(context: try makeContext())
    let id = UUID()
    #expect(throws: RepositoryError.notFound(id)) { try repository.markUsed(id: id, at: t0) }
  }
}

@MainActor
@Suite struct VisitRepositoryTests {
  private func start(_ repository: SwiftDataVisitRepository) throws -> Visit {
    try repository.startVisit(storeId: UUID(), listId: UUID(), listWasSorted: true, at: t0)
  }

  @Test func subjectSetsExactlyOneOfProductOrCategory() throws {
    let repository = SwiftDataVisitRepository(context: try makeContext())
    let visit = try start(repository)
    let product = UUID()
    let byProduct = try repository.addCheck(
      visitId: visit.id, itemId: UUID(), subject: .product(product), checkedAt: t0)
    let byCategory = try repository.addCheck(
      visitId: visit.id, itemId: UUID(), subject: .category("dairy"), checkedAt: t0.addingTimeInterval(1))

    #expect(byProduct.productId == product && byProduct.categoryId == nil)
    #expect(byCategory.productId == nil && byCategory.categoryId == "dairy")
    #expect(try repository.checks(visitId: visit.id).map(\.id) == [byProduct.id, byCategory.id])
  }

  @Test func closingWithChecksKeepsTheVisit() throws {
    let repository = SwiftDataVisitRepository(context: try makeContext())
    let visit = try start(repository)
    #expect(try repository.openVisit()?.id == visit.id)
    try repository.addCheck(visitId: visit.id, itemId: UUID(), subject: .category("other"), checkedAt: t0)

    #expect(try repository.closeVisit(id: visit.id, at: t0.addingTimeInterval(60)))
    #expect(visit.endedAt == t0.addingTimeInterval(60))
    #expect(try repository.openVisit() == nil)
  }

  @Test func closingWithoutChecksDeletesTheVisit() throws {
    let repository = SwiftDataVisitRepository(context: try makeContext())
    let id = try start(repository).id
    #expect(try !repository.closeVisit(id: id, at: t0))
    #expect(try repository.visit(id: id) == nil)
  }

  @Test func closingTwiceKeepsTheFirstEndDate() throws {
    let repository = SwiftDataVisitRepository(context: try makeContext())
    let visit = try start(repository)
    try repository.addCheck(visitId: visit.id, itemId: UUID(), subject: .category("other"), checkedAt: t0)
    try repository.closeVisit(id: visit.id, at: t0)
    visit.endSyncState = .synced

    #expect(try repository.closeVisit(id: visit.id, at: t0.addingTimeInterval(60)))
    #expect(visit.endedAt == t0)
    #expect(visit.endSyncState == .synced)
  }

  @Test func noCheckAfterClosing() throws {
    let repository = SwiftDataVisitRepository(context: try makeContext())
    let visit = try start(repository)
    try repository.addCheck(visitId: visit.id, itemId: UUID(), subject: .category("other"), checkedAt: t0)
    try repository.closeVisit(id: visit.id, at: t0)
    #expect(throws: RepositoryError.visitClosed(visit.id)) {
      try repository.addCheck(visitId: visit.id, itemId: UUID(), subject: .category("other"), checkedAt: t0)
    }
  }
}

@MainActor
@Suite struct GraphRepositoryTests {
  private func save(_ repository: SwiftDataGraphRepository, _ storeId: UUID, version: Int64, at date: Date) throws {
    try repository.saveSnapshot(
      storeId: storeId, snapshotVersion: version, paramsVersion: 1, confidenceQ: 500, payload: Data([UInt8(version)]),
      at: date)
  }

  @Test func saveReplacesTheSnapshotOfAStore() throws {
    let context = try makeContext()
    let repository = SwiftDataGraphRepository(context: context)
    let store = UUID()
    try save(repository, store, version: 1, at: t0)
    try save(repository, store, version: 2, at: t0.addingTimeInterval(1))

    #expect(try context.fetchCount(FetchDescriptor<GraphSnapshot>()) == 1)
    #expect(try repository.snapshot(storeId: store)?.snapshotVersion == 2)
    #expect(try repository.snapshot(storeId: store)?.payload == Data([2]))
  }

  @Test func onlyTheFiveMostRecentStoresAreKept() throws {
    let context = try makeContext()
    let repository = SwiftDataGraphRepository(context: context)
    let stores = (0..<6).map { _ in UUID() }
    for (offset, store) in stores.enumerated() {
      try save(repository, store, version: 1, at: t0.addingTimeInterval(Double(offset)))
    }

    #expect(try context.fetchCount(FetchDescriptor<GraphSnapshot>()) == SwiftDataGraphRepository.maxSnapshots)
    #expect(try repository.snapshot(storeId: stores[0]) == nil)
    #expect(try repository.snapshot(storeId: stores[5]) != nil)
  }
}

@MainActor
@Suite struct CategorySeedTests {
  private let other = ItemCategory(id: "other", rank: 999, labelFr: "Autre")
  private let dairy = ItemCategory(id: "dairy", rank: 70, labelFr: "Crèmerie")

  private func repository(_ context: ModelContext, _ seed: CategorySeed) -> SwiftDataCategoryRepository {
    SwiftDataCategoryRepository(context: context, seedSource: { seed })
  }

  @Test func seedCopiesDomainResourcesInOrder() throws {
    let repository = SwiftDataCategoryRepository(context: try makeContext())
    try repository.seedIfNeeded()
    let expected = try CategoryResources.categories()
    let seeded = try repository.categories()

    #expect(seeded.map(\.id) == expected.map(\.id))
    #expect(seeded.map(\.rank) == expected.map(\.rank))
    #expect(seeded.map(\.label) == expected.map(\.labelFr))
    #expect(seeded.allSatisfy { $0.slug == $0.id })
  }

  @Test func runningTwiceAtTheSameVersionChangesNothing() throws {
    let repository = SwiftDataCategoryRepository(context: try makeContext())
    try repository.seedIfNeeded()
    let first = try #require(try repository.categories().first)
    first.label = "Version serveur"
    let count = try repository.categories().count
    try repository.seedIfNeeded()

    #expect(try repository.categories().count == count)
    #expect(try repository.categories().first?.label == "Version serveur")
  }

  @Test func addedCategoryAppearsWhenVersionIncreases() throws {
    let context = try makeContext()
    try repository(context, CategorySeed(version: 1, categories: [dairy, other])).seedIfNeeded()
    let bio = ItemCategory(id: "bio", rank: 75, labelFr: "Bio")
    try repository(context, CategorySeed(version: 2, categories: [dairy, bio, other])).seedIfNeeded()

    #expect(
      try repository(context, CategorySeed(version: 2, categories: [])).categories().map(\.id)
        == ["dairy", "bio", "other"])
    #expect(try context.fetch(FetchDescriptor<CategorySeedState>()).map(\.version) == [2])
  }

  @Test func lowerOrEqualVersionIsIgnored() throws {
    let context = try makeContext()
    try repository(context, CategorySeed(version: 2, categories: [dairy, other])).seedIfNeeded()
    try repository(context, CategorySeed(version: 2, categories: [other])).seedIfNeeded()
    try repository(context, CategorySeed(version: 1, categories: [other])).seedIfNeeded()

    #expect(try context.fetchCount(FetchDescriptor<SchemaV1.Category>()) == 2)
  }

  @Test func renamedIdRemapsEveryReferenceInOneSave() throws {
    let context = try makeContext()
    try repository(context, CategorySeed(version: 1, categories: [dairy, other])).seedIfNeeded()
    let item = ListItem(listId: UUID(), label: "Lait", normalizedName: "lait", categoryId: "dairy", position: 0)
    let product = Product(id: UUID(), name: "Lait", normalizedName: "lait", categoryId: "dairy")
    let check = Check(visitId: UUID(), itemId: item.id, productId: nil, categoryId: "dairy")
    let byProduct = Check(visitId: UUID(), itemId: item.id, productId: product.id, categoryId: nil)
    context.insert(item)
    context.insert(product)
    context.insert(check)
    context.insert(byProduct)
    try context.save()

    let renamed = ItemCategory(id: "milk", rank: 70, labelFr: "Lait")
    try repository(context, CategorySeed(version: 2, categories: [renamed, other], renamedIds: ["dairy": "milk"]))
      .seedIfNeeded()

    #expect(!context.hasChanges)
    #expect(try context.fetch(FetchDescriptor<SchemaV1.Category>()).map(\.id).sorted() == ["milk", "other"])
    #expect(item.categoryId == "milk")
    #expect(product.categoryId == "milk")
    #expect(check.categoryId == "milk")
    #expect(byProduct.categoryId == nil)
  }

  @Test func removedIdWithoutSuccessorFallsBackToOther() throws {
    let context = try makeContext()
    try repository(context, CategorySeed(version: 1, categories: [dairy, other])).seedIfNeeded()
    let item = ListItem(listId: UUID(), label: "Lait", normalizedName: "lait", categoryId: "dairy", position: 0)
    context.insert(item)
    try context.save()

    try repository(context, CategorySeed(version: 2, categories: [other])).seedIfNeeded()

    #expect(item.categoryId == "other")
    #expect(try context.fetch(FetchDescriptor<SchemaV1.Category>()).map(\.id) == ["other"])
  }
}
