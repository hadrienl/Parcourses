import Foundation

/// Magasin affichable, indépendant de SwiftData et du réseau.
struct StoreCandidate: Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let chain: String?
  let address: String?
  /// `nil` quand elle n'a pas de sens : position approximative, recherche, magasin récent.
  let distanceM: Double?
}

/// Résultat de l'écran. `withoutStore` : ordre générique, et aucune visite créée (#9 §8).
enum StorePickerOutcome: Equatable, Sendable {
  case store(UUID)
  case withoutStore
}

/// Règles de présentation des magasins proches.
nonisolated enum StoreRanking {
  static let preciseRadiusM = 3000
  static let approximateRadiusM = 10000
  static let maxResults = 10
  static let recentLimit = 5
  static let searchLimit = 20
  /// Au-delà, le magasin n'est pas proposé d'office (#9 §8).
  static let proposalMaxDistanceM = 150.0
  /// Précision de « nettement plus proche » : écart minimal avec le deuxième magasin, relevé par l'imprécision du point.
  static let proposalMinGapM = 50.0

  /// Magasin à proposer en tête : l'écart doit dépasser ce que l'imprécision du point peut expliquer.
  static func proposal(in stores: [StoreCandidate], fix: LocationFix) -> StoreCandidate? {
    guard !fix.isStale, fix.horizontalAccuracy <= FixSelection.targetAccuracy else { return nil }
    let ranked = stores.filter { $0.distanceM != nil }.sorted { ($0.distanceM ?? 0) < ($1.distanceM ?? 0) }
    guard let first = ranked.first, let distance = first.distanceM, distance < proposalMaxDistanceM else { return nil }
    guard ranked.count > 1, let next = ranked[1].distanceM else { return first }
    return next - distance >= max(proposalMinGapM, fix.horizontalAccuracy) ? first : nil
  }
}

/// Borne une requête distante : sans réponse à temps, c'est comme sans réseau.
nonisolated func withRemoteTimeout<T: Sendable>(
  _ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw RemoteError.network
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else { throw RemoteError.network }
    return first
  }
}

/// Modèle de l'écran de choix du magasin (#9 §8 et §9).
@Observable
final class StorePickerModel {
  enum State: Equatable {
    case loading
    /// Position précise : un magasin proposé (ou aucun si c'est ambigu), puis les autres.
    case precise(proposed: StoreCandidate?, others: [StoreCandidate])
    /// Position approximative : aucune devinette, candidats à égalité.
    case approximate([StoreCandidate])
    /// Localisation refusée.
    case denied
    /// Autorisé, mais aucun point obtenu.
    case locationUnavailable
    case offline
    /// Le service a répondu par une erreur : réessayable, sans donner le réseau pour coupable.
    case serviceError
    /// Aucun magasin dans le rayon.
    case noStore
  }

  /// Le résultat d'une recherche par nom.
  enum SearchState: Equatable {
    case idle
    case searching
    case results([StoreCandidate])
    case offline
    case failed
  }

  static let minimumQueryLength = 2

  private(set) var state = State.loading
  private(set) var recents: [StoreCandidate] = []
  private(set) var search = SearchState.idle
  private(set) var selectionFailed = false
  /// La demande de précision temporaire n'a rien donné : à dire, sinon le bouton semble sans effet.
  private(set) var precisionDeclined = false
  /// Faux en cas de restriction : les Réglages ne permettent pas de lever le refus.
  private(set) var canOpenSettings = true
  var query = "" {
    didSet { if query != oldValue { scheduleSearch() } }
  }

  /// La recherche par nom sert de repli quand la position n'a rien donné d'utilisable.
  var offersSearch: Bool {
    switch state {
    case .denied, .locationUnavailable, .noStore, .approximate: true
    case .loading, .precise, .offline, .serviceError: false
    }
  }

  private let location: any LocationProvider
  private let gateway: (any RemoteGateway)?
  private let stores: any StoreRepository
  private let onFinish: (StorePickerOutcome) -> Void
  private let now: () -> Date
  private let debounce: Duration
  private let requestTimeout: Duration
  private var loadTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?

  /// `gateway` est `nil` sans configuration Supabase : l'app reste locale, comme hors ligne.
  init(
    location: any LocationProvider, gateway: (any RemoteGateway)?, stores: any StoreRepository,
    debounce: Duration = .milliseconds(300), requestTimeout: Duration = .seconds(10),
    now: @escaping () -> Date = { .now },
    onFinish: @escaping (StorePickerOutcome) -> Void
  ) {
    self.location = location
    self.gateway = gateway
    self.stores = stores
    self.debounce = debounce
    self.requestTimeout = requestTimeout
    self.now = now
    self.onFinish = onFinish
  }

  /// Lance le chargement et remplace celui en cours : un seul à la fois.
  /// Autorisation demandée ici, à l'ouverture de l'écran, jamais au lancement de l'app.
  func start() {
    loadTask?.cancel()
    state = .loading
    reloadRecents()
    loadTask = Task { await performLoad() }
  }

  /// Fermeture de l'écran : aucune position ne doit partir ensuite.
  func cancel() {
    loadTask?.cancel()
    searchTask?.cancel()
  }

  /// Lance le chargement et attend sa fin.
  func load() async {
    start()
    await loadTask?.value
  }

  private func performLoad() async {
    let authorization = await location.requestAuthorization()
    guard !Task.isCancelled else { return }
    switch authorization {
    case .denied, .restricted, .notDetermined:
      showDenied(authorization)
    case .approximate, .precise:
      await locate(authorization)
    }
  }

  private func showDenied(_ authorization: LocationAuthorization) {
    lastAuthorization = authorization
    canOpenSettings = authorization != .restricted
    state = .denied
  }

  /// Au retour au premier plan : les Réglages ont pu rendre l'accès à la position.
  func refreshAfterForeground() {
    let wasWaiting: Bool
    switch state {
    case .denied, .approximate: wasWaiting = true
    default: wasWaiting = false
    }
    if wasWaiting && location.authorization != lastAuthorization { start() }
  }

  func requestPrecision() async {
    precisionDeclined = false
    guard await location.requestTemporaryPrecision() == .precise else {
      precisionDeclined = true
      return
    }
    await load()
  }

  func select(_ store: StoreCandidate) {
    do {
      // Distance non conservée : avec le magasin et la date, elle situerait l'utilisateur.
      try stores.upsertStore(
        id: store.id, name: store.name, chain: store.chain, address: store.address, lastDistanceM: nil)
      try stores.markUsed(id: store.id, at: now())
      selectionFailed = false
      cancel()
      onFinish(.store(store.id))
    } catch {
      selectionFailed = true
    }
  }

  func dismissSelectionFailure() {
    selectionFailed = false
  }

  func continueWithoutStore() {
    cancel()
    onFinish(.withoutStore)
  }

  // MARK: - Position

  private var lastAuthorization: LocationAuthorization?

  private func locate(_ authorization: LocationAuthorization) async {
    lastAuthorization = authorization
    guard let gateway else {
      state = .offline
      return
    }
    let fix: LocationFix
    switch await location.currentFix() {
    case .fix(let result): fix = result
    case .denied:
      if !Task.isCancelled { showDenied(location.authorization) }
      return
    case .unavailable:
      if !Task.isCancelled { state = .locationUnavailable }
      return
    }
    guard !Task.isCancelled else { return }
    let isPrecise = authorization == .precise
    let radiusM = isPrecise ? StoreRanking.preciseRadiusM : StoreRanking.approximateRadiusM
    do {
      let rows = try await withRemoteTimeout(requestTimeout) {
        try await gateway.nearbyStores(
          lat: fix.latitude, lng: fix.longitude, radiusM: radiusM, maxResults: StoreRanking.maxResults)
      }
      guard !Task.isCancelled else { return }
      state = Self.state(from: rows, isPrecise: isPrecise, fix: fix)
    } catch {
      // Une annulation est classée `network` par le gateway : elle ne doit pas afficher « hors ligne ».
      guard !Task.isCancelled else { return }
      state = error as? RemoteError == .network ? .offline : .serviceError
    }
  }

  private static func state(from rows: [NearbyStoreRow], isPrecise: Bool, fix: LocationFix) -> State {
    guard !rows.isEmpty else { return .noStore }
    guard isPrecise else {
      // Le point approximatif ne permet pas de classer : à égalité, par ordre alphabétique.
      let stores = rows.map { StoreCandidate(row: $0, keepsDistance: false) }
      return .approximate(stores.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
    let stores = rows.map { StoreCandidate(row: $0, keepsDistance: true) }
    let proposed = StoreRanking.proposal(in: stores, fix: fix)
    return .precise(proposed: proposed, others: stores.filter { $0.id != proposed?.id })
  }

  private func reloadRecents() {
    // Le cache est un confort : illisible, il ne doit pas bloquer le choix en ligne.
    let cached = (try? stores.recentStores(limit: StoreRanking.recentLimit)) ?? []
    recents = cached.map {
      StoreCandidate(id: $0.id, name: $0.name, chain: $0.chain, address: $0.address, distanceM: nil)
    }
  }

  // MARK: - Recherche

  private func scheduleSearch() {
    searchTask?.cancel()
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= Self.minimumQueryLength else {
      search = .idle
      return
    }
    search = .searching
    guard let gateway else {
      search = .offline
      return
    }
    searchTask = Task { [debounce, requestTimeout] in
      try? await Task.sleep(for: debounce)
      guard !Task.isCancelled else { return }
      do {
        let rows = try await withRemoteTimeout(requestTimeout) {
          try await gateway.searchStores(query: text, limit: StoreRanking.searchLimit)
        }
        guard !Task.isCancelled else { return }
        search = .results(
          rows.map { StoreCandidate(id: $0.id, name: $0.name, chain: $0.chain, address: $0.address, distanceM: nil) })
      } catch {
        guard !Task.isCancelled else { return }
        search = error as? RemoteError == .network ? .offline : .failed
      }
    }
  }
}

extension StoreCandidate {
  fileprivate init(row: NearbyStoreRow, keepsDistance: Bool) {
    self.init(
      id: row.id, name: row.name, chain: row.chain, address: row.address,
      distanceM: keepsDistance ? row.distanceM : nil)
  }
}
