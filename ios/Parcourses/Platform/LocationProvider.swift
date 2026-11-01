import CoreLocation

/// Autorisation de localisation, sans type CoreLocation pour les modèles et les tests.
enum LocationAuthorization: Equatable, Sendable {
  case notDetermined
  case denied
  case approximate
  case precise
}

/// Point lu une seule fois. Il n'a ni `Codable` ni journalisation : il ne vit que le temps d'une recherche.
nonisolated struct LocationFix: Equatable, Sendable {
  let latitude: Double
  let longitude: Double
  let horizontalAccuracy: Double
  let timestamp: Date
}

/// Accès à la position : uniquement « Pendant l'utilisation », une requête ponctuelle à la fois (#9 §8).
protocol LocationProvider {
  var authorization: LocationAuthorization { get }
  /// Affiche la demande système si besoin et renvoie la décision.
  func requestAuthorization() async -> LocationAuthorization
  /// Premier point assez précis, ou le meilleur obtenu à l'échéance. `nil` si aucun point n'est arrivé.
  func currentFix() async -> LocationFix?
  /// Demande la précision temporaire. Renvoie l'autorisation résultante.
  func requestTemporaryPrecision() async -> LocationAuthorization
}

/// Choix du point d'une requête ponctuelle, séparé de CoreLocation pour être testé.
nonisolated enum FixSelection {
  /// Seuil de précision qui met fin à la requête (#9 §8).
  static let targetAccuracy = 100.0
  /// Échéance de la requête (#9 §8).
  static let timeout = Duration.seconds(8)
  /// CoreLocation peut d'abord livrer un point en cache : un point ancien désignerait le mauvais magasin.
  static let maxAge: TimeInterval = 30

  enum Event: Sendable {
    case point(LocationFix)
    case deadline
  }

  /// `acceptsFirstPoint` : en position approximative, le seuil de précision n'est jamais atteint.
  static func select(
    from events: some AsyncSequence<Event, Never>, acceptsFirstPoint: Bool, now: @Sendable () -> Date = { .now }
  ) async -> LocationFix? {
    var best: LocationFix?
    for await event in events {
      switch event {
      case .deadline:
        return best
      case .point(let fix):
        guard fix.horizontalAccuracy >= 0, now().timeIntervalSince(fix.timestamp) <= maxAge else { continue }
        if acceptsFirstPoint || fix.horizontalAccuracy <= targetAccuracy { return fix }
        if fix.horizontalAccuracy < best?.horizontalAccuracy ?? .infinity { best = fix }
      }
    }
    return best
  }
}

/// Implémentation CoreLocation.
final class SystemLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
  /// Clé de `NSLocationTemporaryUsageDescriptionDictionary`.
  static let precisionPurposeKey = "StorePicker"

  private let manager = CLLocationManager()
  private var authorizationWaiters: [CheckedContinuation<LocationAuthorization, Never>] = []

  override init() {
    super.init()
    manager.delegate = self
  }

  var authorization: LocationAuthorization {
    switch manager.authorizationStatus {
    case .notDetermined: .notDetermined
    case .authorizedAlways, .authorizedWhenInUse:
      manager.accuracyAuthorization == .fullAccuracy ? .precise : .approximate
    default: .denied
    }
  }

  func requestAuthorization() async -> LocationAuthorization {
    guard authorization == .notDetermined else { return authorization }
    return await withCheckedContinuation { continuation in
      authorizationWaiters.append(continuation)
      manager.requestWhenInUseAuthorization()
    }
  }

  func currentFix() async -> LocationFix? {
    let events = AsyncStream<FixSelection.Event> { continuation in
      let updates = Task {
        do {
          for try await update in CLLocationUpdate.liveUpdates() {
            guard let location = update.location else { continue }
            continuation.yield(
              .point(
                LocationFix(
                  latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                  horizontalAccuracy: location.horizontalAccuracy, timestamp: location.timestamp)))
          }
        } catch {
          // Sans flux, l'échéance rend le meilleur point déjà reçu.
        }
      }
      let deadline = Task {
        try? await Task.sleep(for: FixSelection.timeout)
        continuation.yield(.deadline)
      }
      continuation.onTermination = { _ in
        updates.cancel()
        deadline.cancel()
      }
    }
    return await FixSelection.select(from: events, acceptsFirstPoint: authorization == .approximate)
  }

  func requestTemporaryPrecision() async -> LocationAuthorization {
    try? await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.precisionPurposeKey)
    return authorization
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    // Appelé aussi à la création du gestionnaire : on attend une vraie décision.
    guard authorization != .notDetermined else { return }
    let waiters = authorizationWaiters
    authorizationWaiters = []
    for waiter in waiters { waiter.resume(returning: authorization) }
  }
}
