#if DEBUG
  import Foundation

  /// Tests UI de la purge qui échoue (#129), Debug seulement : `PARCOURSES_TEST_PURGE_FAILURES=<n>` fait échouer les
  /// `n` premières purges du processus à leur première étape (base locale), avant d'y toucher, comme un stockage
  /// plein. Les suivantes aboutissent : « Réessayer » finit par réussir.
  enum UITestPurgeFailures {
    static let variable = "PARCOURSES_TEST_PURGE_FAILURES"

    /// Erreur simulée.
    struct Simulated: Error {}

    /// Échecs encore à produire, communs aux purges de la déconnexion, du changement de compte et de la suppression.
    private static var remaining = ProcessInfo.processInfo.environment[variable].flatMap(Int.init) ?? 0

    /// Passé à `LocalDataPurge` : lève à la première étape tant qu'il reste des échecs à produire.
    static func inject(_ step: LocalDataPurge.Step) throws {
      guard step == .storePurged, remaining > 0 else { return }
      remaining -= 1
      throw Simulated()
    }
  }
#endif
