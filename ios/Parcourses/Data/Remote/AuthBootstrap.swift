import Foundation
import OSLog

/// Prépare l'accès distant au lancement. Sans configuration, l'app reste entièrement locale.
enum AuthBootstrap {
  static let installedFlag = "auth.installed"
  private static let logger = Logger(subsystem: "app.parcourses", category: "auth")

  static func makeGateway(
    bundle: Bundle = .main,
    defaults: UserDefaults = .standard,
    keychain: KeychainStore = KeychainStore()
  ) -> (any RemoteGateway)? {
    resetAfterReinstall(defaults: defaults, keychain: keychain)
    guard let configuration = SupabaseConfiguration(bundle: bundle) else { return nil }
    return SupabaseGateway(configuration: configuration, keychain: keychain)
  }

  /// Le Keychain survit à la désinstallation, pas `UserDefaults` : une réinstallation repart de zéro.
  static func resetAfterReinstall(defaults: UserDefaults, keychain: KeychainStore) {
    guard !defaults.bool(forKey: installedFlag) else { return }
    do {
      try keychain.removeAll()
      defaults.set(true, forKey: installedFlag)
    } catch {
      // Le drapeau reste absent : on réessaiera au prochain lancement.
      logger.error("Keychain non réinitialisé : \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Connexion anonyme en tâche de fond. Un échec n'empêche rien : tout est local et la file attend.
  static func signIn(_ gateway: any RemoteGateway) async {
    do {
      try await gateway.ensureSession(captchaToken: nil)
    } catch {
      logger.notice("Connexion anonyme reportée : \(String(describing: error), privacy: .public)")
    }
  }
}
