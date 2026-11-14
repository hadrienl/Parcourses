import Foundation
import OSLog
import Observation

/// État du compte pour les écrans (#87 §2.4) : anonyme ou e-mail, adresse, prénom, session à retrouver. Porte aussi
/// la déconnexion et « Continuer sans compte ». Mêmes noms sur Android.
@Observable
final class AccountSession {
  /// Ce que le compte demande au reste de l'app, en plus de l'hôte de la suppression (#68).
  struct Dependencies {
    var isOnline: () -> Bool = { true }
    /// Entrées de la file pas encore parties : la déconnexion prévient qu'elles seront perdues.
    var pendingChanges: () -> Int = { 0 }
    /// Session changée (connexion, compte anonyme recréé) : le moteur reprend.
    var sessionDidChange: () -> Void = {
      // Sans moteur à relancer.
    }
    /// Pour `AccountLink`.
    var link = AccountLink.Dependencies()
  }

  private static let logger = Logger(subsystem: "app.parcourses", category: "account")

  private(set) var kind: AccountKind
  /// Adresse du compte e-mail, connue de la session.
  private(set) var email: String?
  /// Prénom affiché aux membres des listes partagées, lu sur le serveur.
  private(set) var displayName: String?
  /// Compte e-mail sans session sur l'appareil : bandeau « Reconnectez-vous pour synchroniser ».
  private(set) var needsSignIn = false
  /// Déconnexion en cours : voile non annulable.
  private(set) var isSigningOut = false
  /// Câblé par l'app après la construction, comme pour la suppression du compte.
  @ObservationIgnored weak var host: (any AccountDeletionHost)?

  private let gateway: (any RemoteGateway)?
  private let kinds: any AccountKindStore
  private let purge: LocalDataPurge?
  private let dependencies: Dependencies

  /// `gateway` à `nil` : build sans Supabase, aucun compte à lier.
  init(
    gateway: (any RemoteGateway)?, kinds: any AccountKindStore, purge: LocalDataPurge?,
    dependencies: Dependencies = Dependencies()
  ) {
    self.gateway = gateway
    self.kinds = kinds
    self.purge = purge
    self.dependencies = dependencies
    kind = kinds.kind
  }

  /// Un compte peut être lié : l'app parle à un serveur.
  var isAvailable: Bool { gateway != nil }

  /// Relit l'état du compte : au lancement, au retour au premier plan, après une connexion. Un Keychain verrouillé ne
  /// change rien.
  func refresh() async {
    guard let gateway else { return }
    if let address = (try? await gateway.accountEmail()) ?? nil {
      // Session non anonyme : le drapeau suit, même s'il a été perdu.
      if kinds.kind != .email { kinds.save(.email) }
      email = address
    }
    kind = kinds.kind
    do {
      // Session absente : seul un compte e-mail attend une reconnexion (vecteur `009`).
      needsSignIn = try await gateway.localSessionAccountId() == nil && kind == .email
    } catch {
      // Keychain verrouillé : la session existe peut-être, rien ne change.
    }
    guard kind == .email, !needsSignIn, dependencies.isOnline() else { return }
    if let name = try? await withTimeout(AccountLink.timeout, { try await gateway.displayName() }) {
      displayName = name
    }
  }

  /// Nouveau déroulé de connexion, pour la feuille « Se connecter ».
  func makeLink() -> AccountLink? {
    guard let gateway else { return nil }
    var link = dependencies.link
    let base = link.sessionDidChange
    link.sessionDidChange = { [weak self] in
      base()
      self?.needsSignIn = false
      self?.kind = .email
    }
    return AccountLink(gateway: gateway, kinds: kinds, dependencies: link)
  }

  /// Liaison ou connexion terminée : adresse et prénom relus.
  func linkDidFinish() async {
    await refresh()
  }

  /// La déconnexion perdra des modifications pas encore envoyées.
  var losesPendingChanges: Bool { dependencies.pendingChanges() > 0 }

  /// Écrit le prénom. Faux s'il est refusé (forme) ou s'il n'a pas pu partir.
  func updateDisplayName(_ raw: String) async -> Bool {
    guard let gateway, let name = AccountLink.validDisplayName(raw), dependencies.isOnline() else { return false }
    do {
      try await withTimeout(AccountLink.timeout) { try await gateway.setDisplayName(name) }
      displayName = name
      return true
    } catch {
      Self.logger.notice("Prénom non enregistré : \(AuthBootstrap.publicCode(of: error), privacy: .public)")
      return false
    }
  }

  /// Se déconnecter (#87 §2.4) : la session est oubliée, l'appareil purgé (#68), puis un compte anonyme vide naît et
  /// l'app repart. Les listes restent dans le compte ; aucune copie locale ne reste, l'appareil peut être partagé.
  func signOut() async {
    guard let gateway, kind == .email, !isSigningOut else { return }
    isSigningOut = true
    defer { isSigningOut = false }
    host?.endShopping()
    await host?.stopSync()
    do {
      try await withTimeout(AccountLink.timeout) { try await gateway.signOut() }
    } catch {
      // Session oubliée sur l'appareil quoi qu'il arrive ; le jeton serveur expirera.
      Self.logger.notice("Déconnexion serveur reportée : \(AuthBootstrap.publicCode(of: error), privacy: .public)")
    }
    do {
      try purge?.run()
    } catch {
      Self.logger.error("Purge après déconnexion incomplète : \(String(describing: error), privacy: .private)")
    }
    // Le drapeau effacé par la purge, un compte anonyme peut naître. Un échec ici n'empêche rien : la connexion sera
    // retentée au lancement de l'app reconstruite.
    _ = try? await withTimeout(AccountLink.timeout) { try await gateway.ensureSession(captchaToken: nil) }
    kind = kinds.kind
    email = nil
    displayName = nil
    needsSignIn = false
    host?.restart()
  }

  /// « Continuer sans compte » (session perdue) : un compte anonyme naît, `AccountRekey` y renvoie les listes à soi et
  /// retire celles d'autrui (#87 §2.3).
  func continueWithoutAccount() {
    guard needsSignIn else { return }
    kinds.save(.anonymous)
    kind = .anonymous
    email = nil
    displayName = nil
    needsSignIn = false
    dependencies.sessionDidChange()
  }
}
