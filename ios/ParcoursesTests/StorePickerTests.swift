import CoreLocation
import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit

@testable import Parcourses

// MARK: - Doublures

private final class FakeLocation: LocationProvider {
  var authorization: LocationAuthorization
  var decision: LocationAuthorization?
  var result: LocationResult
  /// Requête de position qui ne répond qu'à l'annulation.
  var hangs = false
  var afterPrecision: LocationAuthorization = .approximate
  private(set) var fixRequests = 0

  init(_ authorization: LocationAuthorization, result: LocationResult = .fix(FakeLocation.goodFix)) {
    self.authorization = authorization
    self.result = result
  }

  static let goodFix = LocationFix(latitude: 43.6, longitude: 0.5, horizontalAccuracy: 20, timestamp: .now)

  func requestAuthorization() async -> LocationAuthorization {
    if authorization == .notDetermined, let decision { authorization = decision }
    return authorization
  }

  func currentFix() async -> LocationResult {
    fixRequests += 1
    if hangs { try? await Task.sleep(for: .seconds(60)) }
    return result
  }

  func requestTemporaryPrecision() async -> LocationAuthorization {
    authorization = afterPrecision
    return authorization
  }
}

private actor FakeGateway: RemoteGateway {
  struct NearbyCall: Equatable {
    let lat: Double
    let lng: Double
    let radiusM: Int
  }

  private var nearby: Result<[NearbyStoreRow], RemoteError>
  private var found: Result<[StoreSearchRow], RemoteError>
  private(set) var nearbyCalls: [NearbyCall] = []
  private(set) var searches: [String] = []
  private var searchDelays: [String: Duration] = [:]
  private var nearbyDelay: Duration?

  private var foundByQuery: [String: [StoreSearchRow]] = [:]

  init(
    nearby: Result<[NearbyStoreRow], RemoteError> = .success([]),
    found: Result<[StoreSearchRow], RemoteError> = .success([]),
    nearbyDelay: Duration? = nil,
    foundByQuery: [String: [StoreSearchRow]] = [:],
    searchDelays: [String: Duration] = [:]
  ) {
    self.nearby = nearby
    self.found = found
    self.nearbyDelay = nearbyDelay
    self.foundByQuery = foundByQuery
    self.searchDelays = searchDelays
  }

  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow] {
    nearbyCalls.append(NearbyCall(lat: lat, lng: lng, radiusM: radiusM))
    if let nearbyDelay { try await Task.sleep(for: nearbyDelay) }
    return try nearby.get()
  }

  func searchStores(query: String, limit: Int) async throws -> [StoreSearchRow] {
    searches.append(query)
    // La réponse ignore l'annulation, comme une réponse déjà reçue au moment où la saisie change.
    if let delay = searchDelays[query] { try? await Task.sleep(for: delay) }
    if let rows = foundByQuery[query] { return rows }
    return try found.get()
  }

  func ensureSession(captchaToken: String?) async throws -> UUID { UUID() }
  func acceptCurrentAccount() async throws {}
  func saveList(_ list: ListUpsert) async throws {}
  func deleteList(id: UUID) async throws {}
  func saveItem(_ item: ListItemUpsert) async throws {}
  func deleteItem(id: UUID) async throws {}
  func createVisit(_ visit: VisitInsert) async throws {}
  func insertChecks(_ checks: [CheckUpload]) async throws {}
  func closeVisit(id: UUID, endedAt: Date) async throws {}
  func fetchLists(updatedAfter: Date?) async throws -> [ListRow] { [] }
  func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow] { [] }
  func fetchCategories() async throws -> [CategoryRow] { [] }
  func fetchProducts() async throws -> [RemoteProduct] { [] }
}

private func row(_ name: String, _ distance: Double, address: String? = nil) -> NearbyStoreRow {
  NearbyStoreRow(id: UUID(), name: name, chain: nil, address: address, distanceM: distance)
}

private func candidate(_ distance: Double?) -> StoreCandidate {
  StoreCandidate(id: UUID(), name: "M", chain: nil, address: nil, distanceM: distance)
}

private func makeStores() throws -> SwiftDataStoreRepository {
  let container = try PersistenceStack.makeContainer(storage: .inMemory)
  retained.append(container)
  return SwiftDataStoreRepository(context: container.mainContext)
}

/// Un `ModelContext` ne retient pas son conteneur.
@MainActor private var retained: [ModelContainer] = []

// MARK: - Choix du point

@Suite struct FixSelectionTests {
  private nonisolated static let now = Date(timeIntervalSince1970: 1_000_000)

  private func fix(accuracy: Double, age: TimeInterval = 0) -> LocationFix {
    LocationFix(
      latitude: 1, longitude: 2, horizontalAccuracy: accuracy, timestamp: Self.now.addingTimeInterval(-age))
  }

  private func select(_ events: [FixSelection.Event], approximate: Bool = false) async -> LocationResult {
    let stream = AsyncStream<FixSelection.Event> { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
    return await FixSelection.select(from: stream, isApproximate: approximate, now: { Self.now })
  }

  private func accuracy(_ result: LocationResult) -> Double? {
    if case .fix(let fix) = result { return fix.horizontalAccuracy }
    return nil
  }

  @Test func stopsAtFirstAccuratePoint() async {
    let result = await select([.point(fix(accuracy: 300)), .point(fix(accuracy: 80)), .point(fix(accuracy: 5))])
    #expect(accuracy(result) == 80)
  }

  @Test func deadlineReturnsBestPointSoFar() async {
    let result = await select([
      .point(fix(accuracy: 300)), .point(fix(accuracy: 150)), .point(fix(accuracy: 200)), .deadline,
    ])
    #expect(accuracy(result) == 150)
  }

  @Test func deadlineWithoutPointIsUnavailable() async {
    #expect(await select([.deadline]) == .unavailable)
  }

  @Test func invalidPointIsIgnored() async {
    #expect(await select([.point(fix(accuracy: -1)), .deadline]) == .unavailable)
  }

  /// Utilisateur immobile : le seul point reçu est vieux. Il est gardé pour la liste, marqué périmé.
  @Test func precisionKeepsStalePointMarked() async {
    let result = await select([.point(fix(accuracy: 10, age: 600)), .deadline])
    guard case .fix(let fix) = result else {
      Issue.record("résultat \(result)")
      return
    }
    #expect(fix.isStale)
  }

  @Test func freshPointBeatsMoreAccurateStalePoint() async {
    let result = await select([.point(fix(accuracy: 10, age: 600)), .point(fix(accuracy: 300)), .deadline])
    #expect(accuracy(result) == 300)
  }

  @Test func stalePointDoesNotEndThePreciseRequest() async {
    let result = await select([.point(fix(accuracy: 10, age: 600)), .point(fix(accuracy: 50))])
    #expect(accuracy(result) == 50)
  }

  @Test func approximateAcceptsFirstPointEvenTenMinutesOld() async {
    let result = await select([.point(fix(accuracy: 3000, age: 600))], approximate: true)
    guard case .fix(let fix) = result else {
      Issue.record("résultat \(result)")
      return
    }
    #expect(fix.horizontalAccuracy == 3000)
    #expect(!fix.isStale)
  }

  @Test func revokedAuthorizationEndsAtOnce() async {
    #expect(await select([.point(fix(accuracy: 300)), .denied, .point(fix(accuracy: 5))]) == .denied)
  }
}

// MARK: - Règles

@Suite struct StoreRankingTests {
  private func fix(accuracy: Double, stale: Bool = false) -> LocationFix {
    LocationFix(latitude: 0, longitude: 0, horizontalAccuracy: accuracy, timestamp: .now, isStale: stale)
  }

  @Test(arguments: [
    ([100.0, 400.0], 20.0, true),
    ([100.0], 20.0, true),
    ([100.0, 150.0], 20.0, true),  // écart de 50 m exactement
    ([100.0, 149.9], 20.0, false),
    ([100.0, 200.0], 100.0, true),  // l'écart suit la précision : 100 m exactement
    ([100.0, 199.9], 100.0, false),
    ([100.0, 400.0], 100.1, false),  // point trop imprécis
    ([149.9, 400.0], 20.0, true),
    ([150.0, 900.0], 20.0, false),  // 150 m exactement : hors proposition
  ])
  func proposal(distances: [Double], accuracy: Double, proposed: Bool) {
    let stores = distances.map { candidate($0) }
    #expect(StoreRanking.proposal(in: stores, fix: fix(accuracy: accuracy))?.id == (proposed ? stores[0].id : nil))
  }

  @Test func proposalSortsDefensively() {
    let far = candidate(400)
    let near = candidate(100)
    #expect(StoreRanking.proposal(in: [far, near], fix: fix(accuracy: 20))?.id == near.id)
  }

  @Test func stalePointNeverProposes() {
    #expect(StoreRanking.proposal(in: [candidate(10)], fix: fix(accuracy: 5, stale: true)) == nil)
  }

  @Test func distanceIsRounded() {
    #expect(StoreDistance.text(metres: 123) == "120 m")
    #expect(StoreDistance.text(metres: 994) == "990 m")
    #expect(StoreDistance.text(metres: 996).hasPrefix("1,0"))
    #expect(StoreDistance.text(metres: 2460).hasPrefix("2,5"))
  }
}

// MARK: - États de l'écran

@Suite struct StorePickerModelTests {
  private func model(
    _ location: FakeLocation, _ gateway: (any RemoteGateway)?, stores: (any StoreRepository)? = nil,
    debounce: Duration = .zero, timeout: Duration = .seconds(10),
    onFinish: @escaping (StorePickerOutcome) -> Void = { _ in }
  ) throws -> StorePickerModel {
    StorePickerModel(
      location: location, gateway: gateway, stores: try stores ?? makeStores(), debounce: debounce,
      requestTimeout: timeout,
      onFinish: onFinish)
  }

  @Test func preciseProposesClearlyNearestStoreWithin3km() async throws {
    let near = row("Proche", 60)
    let far = row("Loin", 900)
    let gateway = FakeGateway(nearby: .success([near, far]))
    let picker = try model(FakeLocation(.precise), gateway)
    await picker.load()
    guard case .precise(let proposed, let others) = picker.state else {
      Issue.record("état \(picker.state)")
      return
    }
    #expect(proposed?.id == near.id)
    #expect(others.map(\.id) == [far.id])
    #expect(await gateway.nearbyCalls.map(\.radiusM) == [3000])
  }

  @Test func preciseWithoutClearWinnerProposesNothing() async throws {
    let picker = try model(FakeLocation(.precise), FakeGateway(nearby: .success([row("A", 60), row("B", 70)])))
    await picker.load()
    guard case .precise(nil, let others) = picker.state else {
      Issue.record("état \(picker.state)")
      return
    }
    #expect(others.count == 2)
  }

  @Test func approximateListsCandidatesEquallyWithin10km() async throws {
    let gateway = FakeGateway(nearby: .success([row("Zèbre", 10), row("Atout", 5000)]))
    let picker = try model(FakeLocation(.approximate), gateway)
    await picker.load()
    guard case .approximate(let stores) = picker.state else {
      Issue.record("état \(picker.state)")
      return
    }
    #expect(stores.map(\.name) == ["Atout", "Zèbre"])
    #expect(stores.allSatisfy { $0.distanceM == nil })
    #expect(await gateway.nearbyCalls.map(\.radiusM) == [10000])
    #expect(picker.offersSearch)
  }

  @Test func temporaryPrecisionReloadsAsPrecise() async throws {
    let location = FakeLocation(.approximate)
    location.afterPrecision = .precise
    let picker = try model(location, FakeGateway(nearby: .success([row("A", 60)])))
    await picker.load()
    await picker.requestPrecision()
    guard case .precise(let proposed, _) = picker.state else {
      Issue.record("état \(picker.state)")
      return
    }
    #expect(proposed?.name == "A")
  }

  @Test func refusedPrecisionKeepsApproximateList() async throws {
    let store = row("A", 60)
    let picker = try model(FakeLocation(.approximate), FakeGateway(nearby: .success([store])))
    await picker.load()
    await picker.requestPrecision()
    let expected = StoreCandidate(id: store.id, name: "A", chain: nil, address: nil, distanceM: nil)
    #expect(picker.state == .approximate([expected]))
  }

  @Test func deniedNeverReadsPositionNorCallsNearby() async throws {
    let location = FakeLocation(.denied)
    let gateway = FakeGateway()
    let picker = try model(location, gateway)
    await picker.load()
    #expect(picker.state == .denied)
    #expect(picker.offersSearch)
    #expect(location.fixRequests == 0)
    #expect(await gateway.nearbyCalls.isEmpty)
  }

  @Test func firstRequestFollowsUserDecision() async throws {
    let location = FakeLocation(.notDetermined)
    location.decision = .denied
    let picker = try model(location, FakeGateway())
    await picker.load()
    #expect(picker.state == .denied)
  }

  @Test func returningFromSettingsReloads() async throws {
    let location = FakeLocation(.denied)
    let picker = try model(location, FakeGateway(nearby: .success([row("A", 60)])))
    await picker.load()
    location.authorization = .precise
    picker.refreshAfterForeground()
    #expect(picker.state == .loading)
    while picker.state == .loading { await Task.yield() }
    guard case .precise = picker.state else {
      Issue.record("état \(picker.state)")
      return
    }
  }

  @Test func networkFailureIsOfflineWithRecents() async throws {
    let stores = try makeStores()
    let id = UUID()
    try stores.upsertStore(id: id, name: "Récent", chain: nil, address: nil, lastDistanceM: nil)
    try stores.markUsed(id: id, at: .now)
    let picker = try model(FakeLocation(.precise), FakeGateway(nearby: .failure(.network)), stores: stores)
    await picker.load()
    #expect(picker.state == .offline)
    #expect(picker.recents.map(\.id) == [id])
  }

  @Test func missingConfigurationBehavesAsOffline() async throws {
    let picker = try model(FakeLocation(.precise), nil)
    await picker.load()
    #expect(picker.state == .offline)
  }

  @Test func serverFailureIsNotCalledOffline() async throws {
    let picker = try model(FakeLocation(.precise), FakeGateway(nearby: .failure(.server(code: "500"))))
    await picker.load()
    #expect(picker.state == .serviceError)
  }

  @Test func noPointIsLocationUnavailable() async throws {
    let picker = try model(FakeLocation(.precise, result: .unavailable), FakeGateway())
    await picker.load()
    #expect(picker.state == .locationUnavailable)
    #expect(picker.offersSearch)
  }

  @Test func noStoreOffersSearchAndExitWithoutStore() async throws {
    var outcome: StorePickerOutcome?
    let picker = try model(FakeLocation(.precise), FakeGateway()) { outcome = $0 }
    await picker.load()
    #expect(picker.state == .noStore)
    picker.continueWithoutStore()
    #expect(outcome == .withoutStore)
  }

  /// Le cache ne garde que le magasin choisi, sans distance : rien ne doit permettre de situer l'utilisateur.
  @Test func selectionCachesOnlyChosenStoreWithoutDistance() async throws {
    let stores = try makeStores()
    let chosen = row("Choisi", 60, address: "1 rue")
    let other = row("Autre", 900)
    var outcome: StorePickerOutcome?
    let picker = try model(
      FakeLocation(.precise), FakeGateway(nearby: .success([chosen, other])), stores: stores
    ) { outcome = $0 }
    await picker.load()
    guard case .precise(let proposed?, _) = picker.state else {
      Issue.record("état \(picker.state)")
      return
    }
    picker.select(proposed)
    #expect(outcome == .store(chosen.id))
    let cached = try #require(try stores.store(id: chosen.id))
    #expect(cached.lastDistanceM == nil)
    #expect(cached.lastUsedAt != nil)
    #expect(cached.address == "1 rue")
    #expect(try stores.store(id: other.id) == nil)
  }

  @Test func searchDebouncesAndShowsResults() async throws {
    let found = StoreSearchRow(id: UUID(), name: "Leclerc", chain: nil, address: "Auch")
    let gateway = FakeGateway(found: .success([found]))
    let picker = try model(FakeLocation(.denied), gateway)
    await picker.load()
    picker.query = "a"
    #expect(picker.search == .idle)
    picker.query = "  Auc "
    #expect(picker.search == .searching)
    await waitForSearch(picker)
    #expect(
      picker.search
        == .results([StoreCandidate(id: found.id, name: "Leclerc", chain: nil, address: "Auch", distanceM: nil)]))
    #expect(await gateway.searches == ["Auc"])
  }

  @Test func staleFixListsStoresWithoutProposing() async throws {
    var stale = FakeLocation.goodFix
    stale.isStale = true
    let picker = try model(
      FakeLocation(.precise, result: .fix(stale)), FakeGateway(nearby: .success([row("A", 10)])))
    await picker.load()
    guard case .precise(nil, let others) = picker.state else {
      Issue.record("état \(picker.state)")
      return
    }
    #expect(others.map(\.name) == ["A"])
  }

  @Test func slowNearbyTimesOutAsOffline() async throws {
    let gateway = FakeGateway(nearby: .success([row("A", 60)]), nearbyDelay: .seconds(30))
    let picker = try model(FakeLocation(.precise), gateway, timeout: .milliseconds(50))
    await picker.load()
    #expect(picker.state == .offline)
  }

  @Test func unauthorizedIsARetryableServiceError() async throws {
    let picker = try model(FakeLocation(.precise), FakeGateway(nearby: .failure(.unauthorized)))
    await picker.load()
    #expect(picker.state == .serviceError)
  }

  @Test func deniedDuringRequestShowsDenied() async throws {
    let location = FakeLocation(.precise, result: .denied)
    let gateway = FakeGateway()
    let picker = try model(location, gateway)
    await picker.load()
    #expect(picker.state == .denied)
    #expect(await gateway.nearbyCalls.isEmpty)
  }

  @Test func restrictedHidesSettings() async throws {
    let picker = try model(FakeLocation(.restricted), FakeGateway())
    await picker.load()
    #expect(picker.state == .denied)
    #expect(!picker.canOpenSettings)
    let denied = try model(FakeLocation(.denied), FakeGateway())
    await denied.load()
    #expect(denied.canOpenSettings)
  }

  @Test func declinedPrecisionIsReported() async throws {
    let picker = try model(FakeLocation(.approximate), FakeGateway(nearby: .success([row("A", 60)])))
    await picker.load()
    await picker.requestPrecision()
    #expect(picker.precisionDeclined)
  }

  /// Sheet fermée pendant la lecture de la position : aucune position ne part.
  @Test func cancelStopsBeforeSendingPosition() async throws {
    let location = FakeLocation(.precise)
    location.hangs = true
    let gateway = FakeGateway()
    let picker = try model(location, gateway)
    picker.start()
    while location.fixRequests == 0 { await Task.yield() }
    picker.cancel()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await gateway.nearbyCalls.isEmpty)
    #expect(picker.state == .loading)
  }

  /// Une relance remplace la précédente : une seule position part.
  @Test func restartReplacesRunningLoad() async throws {
    let location = FakeLocation(.precise)
    location.hangs = true
    let gateway = FakeGateway(nearby: .success([row("A", 60)]))
    let picker = try model(location, gateway)
    picker.start()
    while location.fixRequests == 0 { await Task.yield() }
    location.hangs = false
    await picker.load()
    #expect(await gateway.nearbyCalls.count == 1)
  }

  @Test func exitIsPossibleWhileLoading() async throws {
    let location = FakeLocation(.precise)
    location.hangs = true
    var outcome: StorePickerOutcome?
    let gateway = FakeGateway()
    let picker = try model(location, gateway) { outcome = $0 }
    picker.start()
    while location.fixRequests == 0 { await Task.yield() }
    #expect(picker.state == .loading)
    picker.continueWithoutStore()
    #expect(outcome == .withoutStore)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await gateway.nearbyCalls.isEmpty)
  }

  @Test func fastTypingSendsOnlyTheLastQuery() async throws {
    let gateway = FakeGateway()
    let picker = try model(FakeLocation(.denied), gateway, debounce: .milliseconds(100))
    await picker.load()
    picker.query = "Le"
    picker.query = "Lec"
    picker.query = "Lecl"
    await waitForSearch(picker)
    #expect(await gateway.searches == ["Lecl"])
  }

  /// La réponse lente de l'ancienne saisie arrive après la nouvelle : elle ne l'écrase pas.
  @Test func staleSearchDoesNotOverwriteNewerResults() async throws {
    let old = StoreSearchRow(id: UUID(), name: "Ancien", chain: nil, address: nil)
    let new = StoreSearchRow(id: UUID(), name: "Nouveau", chain: nil, address: nil)
    let gateway = FakeGateway(
      foundByQuery: ["ab": [old], "abc": [new]], searchDelays: ["ab": .milliseconds(200)])
    let picker = try model(FakeLocation(.denied), gateway)
    await picker.load()
    picker.query = "ab"
    while await gateway.searches.isEmpty { await Task.yield() }
    picker.query = "abc"
    await waitForSearch(picker)
    try await Task.sleep(for: .milliseconds(300))
    guard case .results(let rows) = picker.search else {
      Issue.record("recherche \(picker.search)")
      return
    }
    #expect(rows.map(\.name) == ["Nouveau"])
  }

  @Test func searchOfflineIsReported() async throws {
    let picker = try model(FakeLocation(.denied), FakeGateway(found: .failure(.network)))
    await picker.load()
    picker.query = "Auch"
    await waitForSearch(picker)
    #expect(picker.search == .offline)
  }

  private func waitForSearch(_ picker: StorePickerModel) async {
    for _ in 0..<200 where picker.search == .searching { try? await Task.sleep(for: .milliseconds(10)) }
  }
}

// MARK: - Vérifications locales (ignorées en CI)

private nonisolated enum LocalRun {
  static let captureDirectory = ProcessInfo.processInfo.environment["PARCOURSES_CAPTURE_DIR"]
  static let liveLocation = ProcessInfo.processInfo.environment["PARCOURSES_LIVE_LOCATION"] != nil
}

/// `TEST_RUNNER_PARCOURSES_CAPTURE_DIR=<dossier> xcodebuild test` : images des états pour la PR.
@Suite(.serialized, .enabled(if: LocalRun.captureDirectory != nil))
struct StorePickerCaptures {
  private static let directory = URL(filePath: LocalRun.captureDirectory ?? "/tmp")

  private func capture(
    _ name: String, _ location: FakeLocation, _ gateway: any RemoteGateway, recents: [String] = [],
    query: String? = nil
  ) async throws {
    let stores = try makeStores()
    for recent in recents {
      let id = UUID()
      try stores.upsertStore(id: id, name: recent, chain: nil, address: "Auch", lastDistanceM: nil)
      try stores.markUsed(id: id, at: .now)
    }
    let model = StorePickerModel(location: location, gateway: gateway, stores: stores, debounce: .zero) { _ in }
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView: StorePickerView(model: model))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .seconds(1))
    if let query {
      model.query = query
      try await Task.sleep(for: .seconds(1))
    }
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    let version = UIDevice.current.systemVersion.split(separator: ".").first ?? ""
    let file = Self.directory.appending(path: "ios-9-8-\(name)-ios\(version).png")
    try #require(image.pngData()).write(to: file)
  }

  private let nearby = [
    row("Leclerc Auch", 62, address: "Route de Tarbes, Auch"),
    NearbyStoreRow(
      id: UUID(), name: "Intermarché Auch", chain: nil, address: "Avenue d'Altigny, Auch", distanceM: 1240),
    row("Carrefour Market", 2460, address: "Rue Gambetta, Auch"),
  ]

  @Test func allStates() async throws {
    try await capture("1-precis", FakeLocation(.precise), FakeGateway(nearby: .success(nearby)))
    try await capture("2-approximatif", FakeLocation(.approximate), FakeGateway(nearby: .success(nearby)))
    let found = StoreSearchRow(id: UUID(), name: "Leclerc Auch", chain: nil, address: "Route de Tarbes, Auch")
    try await capture(
      "3-refus", FakeLocation(.denied), FakeGateway(found: .success([found])), recents: ["Intermarché Auch"],
      query: "Lecl")
    try await capture(
      "4-hors-ligne", FakeLocation(.precise), FakeGateway(nearby: .failure(.network)),
      recents: ["Leclerc Auch", "Intermarché Auch"])
    try await capture("5-aucun", FakeLocation(.precise), FakeGateway())
  }
}

/// Vraie position : `simctl privacy <udid> grant location app.parcourses`, `simctl location <udid> set 43.646,0.586`,
/// puis `TEST_RUNNER_PARCOURSES_LIVE_LOCATION=1 xcodebuild test`.
@Suite(.enabled(if: LocalRun.liveLocation))
struct SystemLocationProviderLiveTests {
  @Test func readsSimulatedPositionOnce() async throws {
    let provider = SystemLocationProvider()
    #expect(provider.authorization == .precise)
    guard case .fix(let fix) = await provider.currentFix() else {
      Issue.record("aucun point")
      return
    }
    #expect(abs(fix.latitude - 43.646) < 0.01)
    #expect(abs(fix.longitude - 0.586) < 0.01)
  }
}
