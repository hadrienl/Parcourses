#if DEBUG
  import Foundation

  /// Tests UI et captures App Store (#145), Debug seulement : `PARCOURSES_TEST_LOCATION=<latitude>,<longitude>` donne
  /// une position précise imposée, sans demande système ni CoreLocation. Rien n'est conservé, comme pour la vraie.
  final class UITestLocationProvider: LocationProvider {
    static let variable = "PARCOURSES_TEST_LOCATION"

    private let latitude: Double
    private let longitude: Double

    /// `nil` sans la variable, ou si elle ne se lit pas comme « latitude,longitude ».
    static func fromEnvironment() -> UITestLocationProvider? {
      guard let raw = ProcessInfo.processInfo.environment[variable] else { return nil }
      let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
      guard parts.count == 2 else { return nil }
      return UITestLocationProvider(latitude: parts[0], longitude: parts[1])
    }

    init(latitude: Double, longitude: Double) {
      self.latitude = latitude
      self.longitude = longitude
    }

    var authorization: LocationAuthorization { .precise }

    func requestAuthorization() async -> LocationAuthorization { .precise }

    func currentFix() async -> LocationResult {
      .fix(LocationFix(latitude: latitude, longitude: longitude, horizontalAccuracy: 10, timestamp: .now))
    }

    func requestTemporaryPrecision() async -> LocationAuthorization { .precise }
  }
#endif
