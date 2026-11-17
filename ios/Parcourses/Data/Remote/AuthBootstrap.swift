import Foundation
import OSLog

/// Prépare l'accès distant au lancement. Sans configuration, l'app reste entièrement locale.
enum AuthBootstrap {
  /// Absent : le Keychain doit être vidé avant tout accès (réinstallation, ou vidage reporté par
  /// `GuardedSecureStore.clear()`, #133).
  nonisolated static let installedFlag = "auth.installed"
  /// Argument de lancement des tests UI (Debug seulement) : l'app reste entièrement locale.
  static let localOnlyArgument = "PARCOURSES_TEST_LOCAL_ONLY"
  private static let logger = Logger(subsystem: "app.parcourses", category: "auth")

  /// `keychain` : l'instance partagée de l'app, la même que celle de `LocalDataPurge`.
  static func makeGateway(bundle: Bundle = .main, keychain: GuardedSecureStore) -> (any RemoteGateway)? {
    resetAfterReinstall(keychain: keychain)
    #if DEBUG
      // Tests UI : build sans passerelle, quel que soit `Local.xcconfig`.
      if ProcessInfo.processInfo.arguments.contains(localOnlyArgument) { return nil }
      // Tests UI du partage (#87, lot 87.4) : serveur en mémoire.
      if let gateway = UITestSharingGateway.fromEnvironment() { return gateway }
    #endif
    guard let configuration = SupabaseConfiguration(bundle: bundle) else { return nil }
    return SupabaseGateway(configuration: configuration, store: keychain)
  }

  /// Le Keychain survit à la désinstallation, pas `UserDefaults` : une réinstallation repart de zéro. Premier essai
  /// du vidage en attente, au lancement ; `GuardedSecureStore` le refait avant tout accès tant qu'il n'a pas abouti.
  static func resetAfterReinstall(keychain: GuardedSecureStore) {
    do {
      try keychain.completePendingWipe()
    } catch {
      // Le drapeau reste absent : aucun accès au Keychain ne passera avant un vidage réussi.
      logger.error(
        "Keychain non réinitialisé : \(publicCode(of: error), privacy: .public) \(String(describing: error), privacy: .private)"
      )
    }
  }

  /// Connexion anonyme en tâche de fond. Un échec n'empêche rien : tout est local et la file attend.
  static func signIn(_ gateway: any RemoteGateway) async {
    do {
      try await gateway.ensureSession(captchaToken: nil)
    } catch {
      logger.notice(
        "Connexion anonyme reportée : \(publicCode(of: error), privacy: .public) \(String(describing: error), privacy: .private)"
      )
    }
  }

  /// Seuls ces codes sont journalisés en clair : ils ne contiennent ni jeton ni donnée de l'utilisateur.
  nonisolated static func publicCode(of error: any Error) -> String {
    switch error {
    case let error as KeychainError: "OSStatus \(error.status)"
    case let error as RemoteError: String(describing: error)
    default: "non classée"
    }
  }
}
