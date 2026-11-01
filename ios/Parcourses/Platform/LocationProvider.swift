import CoreLocation

/// Autorisation de localisation, sans type CoreLocation pour les modèles et les tests.
enum LocationAuthorization: Equatable, Sendable {
  case notDetermined
  case denied
  /// Contrôle parental ou profil : les Réglages n'y peuvent rien.
  case restricted
  case approximate
  case precise
}

/// Point lu une seule fois. Il n'a ni `Codable` ni journalisation : il ne vit que le temps d'une recherche.
nonisolated struct LocationFix: Equatable, Sendable {
  let latitude: Double
  let longitude: Double
  let horizontalAccuracy: Double
  let timestamp: Date
  /// Point ancien : il suffit à lister des magasins, jamais à en proposer un.
  var isStale = false
}

/// Issue d'une requête ponctuelle.
nonisolated enum LocationResult: Equatable, Sendable {
  case fix(LocationFix)
  /// L'autorisation est retirée pendant la requête.
  case denied
  /// Aucun point à l'échéance.
  case unavailable
}

/// Accès à la position : uniquement « Pendant l'utilisation », une requête ponctuelle à la fois (#9 §8).
protocol LocationProvider {
  var authorization: LocationAuthorization { get }
  /// Affiche la demande système si besoin et renvoie la décision.
  func requestAuthorization() async -> LocationAuthorization
  /// Premier point assez précis, ou le meilleur obtenu à l'échéance.
  func currentFix() async -> LocationResult
  /// Demande la précision temporaire. Renvoie l'autorisation résultante.
  func requestTemporaryPrecision() async -> LocationAuthorization
}

/// Choix du point d'une requête ponctuelle, séparé de CoreLocation pour être testé.
nonisolated enum FixSelection {
  /// Seuil de précision qui met fin à la requête (#9 §8).
  static let targetAccuracy = 100.0
  /// Échéance de la requête (#9 §8).
  static let timeout = Duration.seconds(8)
  /// CoreLocation peut livrer un point en cache : un point ancien pourrait désigner le mauvais magasin.
  /// Il arrive aussi seul quand l'utilisateur ne bouge pas : il est donc gardé, marqué périmé.
  static let maxAge: TimeInterval = 30

  enum Event: Sendable {
    case point(LocationFix)
    case denied
    case deadline
  }

  /// `isApproximate` : le seuil de précision n'est jamais atteint et le premier point suffit, quel que soit son âge.
  static func select(
    from events: some AsyncSequence<Event, Never>, isApproximate: Bool, now: @Sendable () -> Date = { .now }
  ) async -> LocationResult {
    var best: LocationFix?
    for await event in events {
      switch event {
      case .deadline:
        return best.map(LocationResult.fix) ?? .unavailable
      case .denied:
        return .denied
      case .point(var fix):
        guard fix.horizontalAccuracy >= 0 else { continue }
        if isApproximate { return .fix(fix) }
        fix.isStale = now().timeIntervalSince(fix.timestamp) > maxAge
        if !fix.isStale && fix.horizontalAccuracy <= targetAccuracy { return .fix(fix) }
        if best.map({ isBetter(fix, than: $0) }) ?? true { best = fix }
      }
    }
    return best.map(LocationResult.fix) ?? .unavailable
  }

  /// Un point récent passe devant un point périmé, même plus précis.
  private static func isBetter(_ fix: LocationFix, than other: LocationFix) -> Bool {
    if fix.isStale != other.isStale { return other.isStale }
    return fix.horizontalAccuracy < other.horizontalAccuracy
  }
}

/// Implémentation CoreLocation.
final class SystemLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
  /// Clé de `NSLocationTemporaryUsageDescriptionDictionary`.
  static let precisionPurposeKey = "StorePicker"

  private let manager = CLLocationManager()
  private var authorizationWaiters: [UUID: CheckedContinuation<LocationAuthorization, Never>] = [:]

  override init() {
    super.init()
    manager.delegate = self
  }

  var authorization: LocationAuthorization {
    switch manager.authorizationStatus {
    case .notDetermined: .notDetermined
    case .authorizedAlways, .authorizedWhenInUse:
      manager.accuracyAuthorization == .fullAccuracy ? .precise : .approximate
    case .restricted: .restricted
    default: .denied
    }
  }

  func requestAuthorization() async -> LocationAuthorization {
    guard authorization == .notDetermined, !Task.isCancelled else { return authorization }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        authorizationWaiters[id] = continuation
        manager.requestWhenInUseAuthorization()
      }
    } onCancel: {
      // Passe après l'enregistrement du waiter : celui-ci a lieu sur le MainActor, sans suspension.
      Task { @MainActor in self.resumeWaiter(id) }
    }
  }

  private func resumeWaiter(_ id: UUID) {
    authorizationWaiters.removeValue(forKey: id)?.resume(returning: authorization)
  }

  func currentFix() async -> LocationResult {
    let events = AsyncStream<FixSelection.Event> { continuation in
      let updates = Task {
        do {
          for try await update in CLLocationUpdate.liveUpdates() {
            if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
              continuation.yield(.denied)
              break
            }
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
    return await FixSelection.select(from: events, isApproximate: authorization == .approximate)
  }

  func requestTemporaryPrecision() async -> LocationAuthorization {
    try? await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.precisionPurposeKey)
    return authorization
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    // Appelé aussi à la création du gestionnaire : on attend une vraie décision.
    guard authorization != .notDetermined else { return }
    for id in authorizationWaiters.keys { resumeWaiter(id) }
  }
}
