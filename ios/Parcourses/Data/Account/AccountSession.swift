import Foundation
import OSLog
import Observation

/// Drapeau durable `account.signOut` : posé avant la déconnexion, effacé après la purge de l'appareil. Un arrêt de
/// l'app entre les deux laisse le drapeau, et la purge est rejouée au lancement suivant, avant toute synchro.
nonisolated protocol AccountSignOutFlagStore: Sendable {
  var isPending: Bool { get }
  func save()
  func clear()
}

/// Dans `UserDefaults.standard`, comme `account.deletion`.
nonisolated struct UserDefaultsAccountSignOutFlagStore: AccountSignOutFlagStore, @unchecked Sendable {
  static let key = "account.signOut"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isPending: Bool { defaults.bool(forKey: Self.key) }
  func save() { defaults.set(true, forKey: Self.key) }
  func clear() { defaults.removeObject(forKey: Self.key) }
}

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
  /// La purge de la déconnexion a échoué : le drapeau reste, « Réessayer » la relance.
  private(set) var signOutFailed = false
  /// Câblé par l'app après la construction, comme pour la suppression du compte.
  @ObservationIgnored weak var host: (any AccountDeletionHost)?

  private let gateway: (any RemoteGateway)?
  private let kinds: any AccountKindStore
  private let purge: LocalDataPurge?
  private let signOutFlags: any AccountSignOutFlagStore
  private let dependencies: Dependencies

  /// `gateway` à `nil` : build sans Supabase, aucun compte à lier.
  init(
    gateway: (any RemoteGateway)?, kinds: any AccountKindStore, purge: LocalDataPurge?,
    signOutFlags: any AccountSignOutFlagStore = UserDefaultsAccountSignOutFlagStore(),
    dependencies: Dependencies = Dependencies()
  ) {
    self.gateway = gateway
    self.kinds = kinds
    self.purge = purge
    self.signOutFlags = signOutFlags
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
    link.pendingChanges = dependencies.pendingChanges
    link.switchAccount = { [weak self] id in
      guard let self else { return }
      try await self.adoptAccount(id)
    }
    return AccountLink(gateway: gateway, kinds: kinds, dependencies: link)
  }

  /// Un compte e-mail se connecte à un autre compte e-mail : l'appareil est purgé (#68), session gardée, puis le nouveau
  /// compte est adopté sans reprise. Les données de l'ancien compte restent sur le serveur.
  func adoptAccount(_ id: UUID) async throws {
    guard let gateway else { return }
    host?.endShopping()
    try purge?.run(keepingSession: true)
    try await gateway.acknowledgeAccount(id)
    kinds.save(.email)
    // Live Activity et « Cocher le suivant » reviennent, fermés par `endShopping` ; la synchro reprend sur le nouveau
    // compte, sans rien à réidentifier.
    host?.resumeSync()
    kind = .email
    email = nil
    displayName = nil
    NotificationCenter.default.post(name: .syncDidChangeData, object: nil)
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
  /// l'app repart. Les listes restent dans le compte ; aucune copie locale ne reste, l'appareil peut être partagé. Le
  /// drapeau `account.signOut` est posé d'abord : un arrêt de l'app avant la fin de la purge la fait rejouer.
  func signOut() async {
    guard let gateway, kind == .email, !isSigningOut else { return }
    signOutFlags.save()
    isSigningOut = true
    defer { isSigningOut = false }
    host?.endShopping()
    await host?.stopSync()
    await forgetSession(gateway)
    await finishSignOut(gateway)
  }

  /// « Réessayer » après une purge en échec.
  func retrySignOut() async {
    guard let gateway, signOutFailed, !isSigningOut else { return }
    signOutFailed = false
    isSigningOut = true
    defer { isSigningOut = false }
    await host?.stopSync()
    await forgetSession(gateway)
    await finishSignOut(gateway)
  }

  /// « Plus tard » : le drapeau reste, la purge reprendra au prochain lancement.
  func postponeSignOutRetry() {
    signOutFailed = false
  }

  /// Au lancement, avant toute synchro : une déconnexion interrompue est achevée. Faux si la purge échoue encore
  /// (« Réessayer » s'affiche, la synchro reste arrêtée).
  func resumePendingSignOut() -> Bool {
    guard signOutFlags.isPending else { return true }
    do {
      try purge?.run()
    } catch {
      Self.logger.error("Purge après déconnexion incomplète : \(String(describing: error), privacy: .private)")
      signOutFailed = true
      return false
    }
    signOutFlags.clear()
    kind = kinds.kind
    email = nil
    displayName = nil
    needsSignIn = false
    return true
  }

  private func forgetSession(_ gateway: any RemoteGateway) async {
    do {
      try await withTimeout(AccountLink.timeout) { try await gateway.signOut() }
    } catch {
      // Session oubliée sur l'appareil quoi qu'il arrive ; le jeton serveur expirera.
      Self.logger.notice("Déconnexion serveur reportée : \(AuthBootstrap.publicCode(of: error), privacy: .public)")
    }
  }

  /// Purge, puis compte anonyme et app reconstruite. Purge en échec : ni reconstruction ni compte, « Réessayer ».
  private func finishSignOut(_ gateway: any RemoteGateway) async {
    do {
      try purge?.run()
    } catch {
      Self.logger.error("Purge après déconnexion incomplète : \(String(describing: error), privacy: .private)")
      signOutFailed = true
      return
    }
    signOutFlags.clear()
    // Le drapeau `account.kind` effacé par la purge, un compte anonyme peut naître. Un échec ici n'empêche rien : la
    // connexion sera retentée au lancement de l'app reconstruite.
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
