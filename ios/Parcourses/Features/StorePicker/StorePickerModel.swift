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
  /// Au-delà, le magasin n'est pas proposé d'office (#9 §8).
  static let proposalMaxDistanceM = 150.0
  /// Précision de « nettement plus proche » : écart minimal avec le deuxième magasin.
  static let proposalMinGapM = 50.0

  /// Magasin à proposer en tête. La liste reçue est triée par distance croissante.
  static func proposal(in stores: [StoreCandidate], accuracyM: Double) -> StoreCandidate? {
    guard accuracyM <= FixSelection.targetAccuracy, let first = stores.first, let distance = first.distanceM,
      distance < proposalMaxDistanceM
    else { return nil }
    guard stores.count > 1 else { return first }
    guard let next = stores[1].distanceM else { return nil }
    return next - distance >= proposalMinGapM ? first : nil
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
  private var searchTask: Task<Void, Never>?

  /// `gateway` est `nil` sans configuration Supabase : l'app reste locale, comme hors ligne.
  init(
    location: any LocationProvider, gateway: (any RemoteGateway)?, stores: any StoreRepository,
    debounce: Duration = .milliseconds(300), now: @escaping () -> Date = { .now },
    onFinish: @escaping (StorePickerOutcome) -> Void
  ) {
    self.location = location
    self.gateway = gateway
    self.stores = stores
    self.debounce = debounce
    self.now = now
    self.onFinish = onFinish
  }

  /// Autorisation demandée ici, à l'ouverture de l'écran, jamais au lancement de l'app.
  func load() async {
    state = .loading
    reloadRecents()
    let authorization = await location.requestAuthorization()
    guard !Task.isCancelled else { return }
    switch authorization {
    case .denied, .notDetermined:
      lastAuthorization = authorization
      state = .denied
    case .approximate, .precise:
      await locate(authorization)
    }
  }

  /// Au retour au premier plan : les Réglages ont pu rendre l'accès à la position.
  func refreshAfterForeground() async {
    let wasWaiting: Bool
    switch state {
    case .denied, .approximate: wasWaiting = true
    default: wasWaiting = false
    }
    if wasWaiting && location.authorization != lastAuthorization { await load() }
  }

  func requestPrecision() async {
    guard await location.requestTemporaryPrecision() == .precise else { return }
    await load()
  }

  func select(_ store: StoreCandidate) {
    do {
      // Distance non conservée : avec le magasin et la date, elle situerait l'utilisateur.
      try stores.upsertStore(
        id: store.id, name: store.name, chain: store.chain, address: store.address, lastDistanceM: nil)
      try stores.markUsed(id: store.id, at: now())
      selectionFailed = false
      onFinish(.store(store.id))
    } catch {
      selectionFailed = true
    }
  }

  func dismissSelectionFailure() {
    selectionFailed = false
  }

  func continueWithoutStore() {
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
    guard let fix = await location.currentFix() else {
      if !Task.isCancelled { state = .locationUnavailable }
      return
    }
    guard !Task.isCancelled else { return }
    let isPrecise = authorization == .precise
    do {
      let rows = try await gateway.nearbyStores(
        lat: fix.latitude, lng: fix.longitude,
        radiusM: isPrecise ? StoreRanking.preciseRadiusM : StoreRanking.approximateRadiusM,
        maxResults: StoreRanking.maxResults)
      guard !Task.isCancelled else { return }
      state = Self.state(from: rows, isPrecise: isPrecise, accuracyM: fix.horizontalAccuracy)
    } catch {
      // Une annulation est classée `network` par le gateway : elle ne doit pas afficher « hors ligne ».
      guard !Task.isCancelled else { return }
      state = error as? RemoteError == .network ? .offline : .serviceError
    }
  }

  private static func state(from rows: [NearbyStoreRow], isPrecise: Bool, accuracyM: Double) -> State {
    guard !rows.isEmpty else { return .noStore }
    guard isPrecise else {
      // Le point approximatif ne permet pas de classer : à égalité, par ordre alphabétique.
      let stores = rows.map { StoreCandidate(row: $0, keepsDistance: false) }
      return .approximate(stores.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
    let stores = rows.map { StoreCandidate(row: $0, keepsDistance: true) }
    let proposed = StoreRanking.proposal(in: stores, accuracyM: accuracyM)
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
    searchTask = Task { [debounce] in
      try? await Task.sleep(for: debounce)
      guard !Task.isCancelled else { return }
      do {
        let rows = try await gateway.searchStores(query: text, limit: StoreSearch.limit)
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
