import Foundation
import OSLog
import Observation

/// Étape de la liaison d'une adresse ou de la connexion (#87 §2.2). Mêmes valeurs sur Android.
nonisolated enum AccountLinkPhase: String, Sendable {
  case enterEmail
  case enterCode
  /// Connexion à un compte existant : `AccountRekey` y ajoute les listes du téléphone, puis la descente.
  case merging
  case done
}

/// Échec annoncé par l'écran de connexion. Mêmes cas sur Android.
nonisolated enum AccountLinkError: Error, Sendable, Equatable {
  /// Adresse mal formée, refusée, ou sans compte quand on ne peut que se connecter.
  case invalidEmail
  case invalidCode
  /// Code plus vieux que sa durée de validité (15 min).
  case expiredCode
  /// Trop de codes demandés, ou trop d'essais.
  case rateLimited
  case offline
  case unknown
}

/// Issue d'une liaison réussie.
nonisolated enum AccountLinkOutcome: Sendable, Equatable {
  /// Adresse liée au compte de l'appareil : même compte, aucune donnée ne bouge.
  case linked
  /// Connexion à un compte existant (« Bon retour ») : `addedLists` listes du téléphone y ont été ajoutées.
  case signedIn(displayName: String?, addedLists: Int)
}

/// Déroulé de la liaison d'une adresse e-mail, ou de la connexion à un compte existant (#87 §2.2, vecteur `010`).
///
/// Compte anonyme : `linkEmail`, puis le code (`email_change`, même compte). Adresse déjà prise : `signInWithEmail`
/// (sans création), puis le code (`email`), `AccountRekey` par la passe de synchronisation qui suit, et suppression de
/// l'ancien compte anonyme avec son jeton gardé (un échec est sans conséquence, #68). Compte e-mail sans session :
/// connexion directe, jamais de liaison. Compte de revue des stores (#149) : aucun code envoyé, puis la même suite
/// qu'une connexion.
@Observable
final class AccountLink {
  /// Ce que la liaison demande au reste de l'app.
  struct Dependencies {
    var isOnline: () -> Bool = { true }
    var now: () -> Date = { .now }
    /// Listes du téléphone qui seront renvoyées si la session passe à ce compte.
    var resendableLists: (UUID) -> Int = { _ in 0 }
    /// Passe complète de synchronisation : reprise des données sur le nouveau compte, puis descente.
    var synchronize: () async -> Void = {
      // Sans moteur : rien à synchroniser.
    }
    /// Session e-mail établie : le moteur reprend, les écrans relisent le compte.
    var sessionDidChange: () -> Void = {
      // Sans moteur ni écran à prévenir.
    }
    /// Compte auquel se rapportent les données de l'appareil (`SyncCursors.accountId`).
    var previousAccountId: () -> UUID? = { nil }
    /// Entrées de la file pas encore parties.
    var pendingChanges: () -> Int = { 0 }
    /// Arrêt de la synchro pendant la vérification du code : aucune requête (ni page suivante) ne part avec le jeton
    /// du nouveau compte sur les données de l'ancien.
    var suspendSync: () async -> Void = {
      // Sans moteur à arrêter.
    }
    /// Attendue : la synchro qui suit doit trouver le moteur reparti.
    var resumeSync: () async -> Void = {
      // Sans moteur à relancer.
    }
    /// Drapeau durable `account.switch` : posé avant `verifyCode` d'une connexion depuis un compte e-mail, effacé quand
    /// le compte n'a pas changé ou quand la purge du changement est faite.
    var markSwitch: (Bool) -> Void = { _ in
      // Sans drapeau durable (aperçus, tests).
    }
    /// Drapeau `account.switch` déjà posé (essai précédent interrompu) : un code refusé ne l'efface pas, la purge
    /// qu'il protège reste due.
    var isSwitchPending: () -> Bool = { false }
    /// Compte e-mail qui se connecte à un autre compte e-mail : l'appareil est purgé, session gardée, et le nouveau
    /// compte adopté. Rien de l'ancien compte n'est renvoyé.
    var switchAccount: (UUID) async throws -> Void = { _ in
      // Sans données locales : rien à purger.
    }
  }

  /// Délai avant « Renvoyer le code ».
  static let resendDelay: TimeInterval = 60
  /// Durée de validité d'un code (`otp_expiry`).
  static let codeLifetime: TimeInterval = 900
  /// Limite de chaque appel au serveur.
  static let timeout = Duration.seconds(15)
  static let codeLength = 6
  private static let logger = Logger(subsystem: "app.parcourses", category: "account")

  private(set) var phase = AccountLinkPhase.enterEmail
  private(set) var error: AccountLinkError?
  /// Change à chaque erreur publiée, même identique : l'écran l'annonce et vide le champ du code.
  private(set) var errorRevision = 0
  private(set) var isWorking = false
  private(set) var outcome: AccountLinkOutcome?
  /// Adresse à laquelle le dernier code est parti.
  private(set) var sentTo: String?
  private(set) var codeSentAt: Date?
  private(set) var purpose: EmailCodePurpose?
  var email = ""
  var displayName = ""

  /// Compte anonyme : le prénom est proposé, et l'adresse se lie au compte de l'appareil.
  let canLink: Bool
  private let gateway: any RemoteGateway
  private let kinds: any AccountKindStore
  private let dependencies: Dependencies
  /// Partagée avec `AccountSession` : la vérification ne chevauche ni un rejeu de lancement ni une déconnexion.
  private let operations: AccountOperationQueue

  init(
    gateway: any RemoteGateway, kinds: any AccountKindStore, dependencies: Dependencies = Dependencies(),
    operations: AccountOperationQueue = AccountOperationQueue()
  ) {
    self.gateway = gateway
    self.kinds = kinds
    self.dependencies = dependencies
    self.operations = operations
    canLink = kinds.kind == .anonymous
  }

  // MARK: - Validation

  /// Adresse telle que le serveur l'enregistre : sans espace, en minuscules.
  var normalizedEmail: String { Self.normalize(email: email) }

  var canRequestCode: Bool {
    Self.isValid(email: normalizedEmail) && isNameAcceptable && !isWorking
  }

  /// Prénom facultatif ; s'il est saisi, il doit être valable.
  var isNameAcceptable: Bool {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Self.validDisplayName(displayName) != nil
  }

  static func normalize(email: String) -> String {
    email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Même forme que les invitations (`invalid_email` côté serveur) : ASCII imprimable, un `@`, un domaine à point.
  static func isValid(email: String) -> Bool {
    email.wholeMatch(of: /[a-z0-9._%+\-]+@[a-z0-9\-]+(\.[a-z0-9\-]+)*\.[a-z]{2,}/) != nil
  }

  /// Prénom accepté par `profiles` : 1 à 40 caractères sans espace en tête ni en fin, sans caractère de contrôle ni
  /// de mise en forme invisible. `nil` s'il ne passe pas.
  static func validDisplayName(_ raw: String) -> String? {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...40).contains(name.unicodeScalars.count) else { return nil }
    let refused: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
    guard !name.unicodeScalars.contains(where: { refused.contains($0.properties.generalCategory) }) else { return nil }
    return name
  }

  /// Compte e-mail sans session : se connecter avec une autre adresse purgerait l'appareil, et des modifications pas
  /// encore envoyées seraient perdues. L'écran le dit avant la demande de code.
  var losesPendingChangesOnSwitch: Bool { !canLink && dependencies.pendingChanges() > 0 }

  /// Secondes avant « Renvoyer le code », 0 s'il est disponible.
  func secondsUntilResend(now: Date) -> Int {
    guard let codeSentAt else { return 0 }
    return max(0, Int((Self.resendDelay - now.timeIntervalSince(codeSentAt)).rounded(.up)))
  }

  // MARK: - Étapes

  /// « Recevoir un code ».
  func requestCode() async {
    guard canRequestCode else {
      if !Self.isValid(email: normalizedEmail) { publish(.invalidEmail) }
      return
    }
    await sendCode(to: normalizedEmail)
  }

  /// « Renvoyer le code », à la même adresse et pour le même usage.
  func resendCode() async {
    guard let sentTo, !isWorking, secondsUntilResend(now: dependencies.now()) == 0 else { return }
    await sendCode(to: sentTo)
  }

  /// « Changer d'adresse ».
  func changeEmail() {
    guard phase == .enterCode, !isWorking else { return }
    phase = .enterEmail
    error = nil
    purpose = nil
    codeSentAt = nil
    sentTo = nil
  }

  /// Validation au 6ᵉ chiffre. La vérification et la reprise tournent dans une tâche à part : ni la fermeture de
  /// l'écran ni l'annulation de l'appelant ne les interrompent (README des vecteurs). Elles attendent leur tour dans la
  /// file des opérations de compte.
  func verify(code raw: String) async {
    let code = raw.filter(\.isASCII).filter(\.isNumber)
    guard phase == .enterCode, !isWorking, code.count == Self.codeLength, let purpose, let sentTo else { return }
    guard dependencies.isOnline() else { return publish(.offline) }
    isWorking = true
    error = nil
    let operations = operations
    let work = Task {
      await operations.run { await self.runVerification(code: code, purpose: purpose, sentTo: sentTo) }
    }
    await work.value
    isWorking = false
  }

  /// La synchro, suspendue avant `verifyCode`, est reprise dans tous les cas, sauf si une purge de changement de
  /// compte reste en attente (drapeau `account.switch`, rejouée au lancement).
  private func runVerification(code: String, purpose: EmailCodePurpose, sentTo: String) async {
    await dependencies.suspendSync()
    var sync = SyncHold.suspended
    await verifyAndMerge(code: code, purpose: purpose, sentTo: sentTo, sync: &sync)
    if sync == .suspended { await dependencies.resumeSync() }
  }

  /// État de la synchro pendant la vérification.
  private enum SyncHold {
    case suspended
    case resumed
    /// Purge en attente : la synchro ne doit pas reprendre avant elle.
    case heldForPurge
  }

  private func verifyAndMerge(code: String, purpose: EmailCodePurpose, sentTo: String, sync: inout SyncHold) async {
    let gateway = gateway
    // Connexion depuis un compte e-mail (compte de revue compris) : le changement de compte éventuel doit survivre à
    // un arrêt de l'app.
    let fromEmailAccount = !canLink && purpose != .link
    // Déjà posé par un essai interrompu : la purge qu'il protège reste due tant que ce code n'a pas abouti.
    let ownsSwitchFlag = fromEmailAccount && !dependencies.isSwitchPending()
    if fromEmailAccount { dependencies.markSwitch(true) }
    let verified: VerifiedCode
    do {
      verified = try await withTimeout(Self.timeout) {
        try await gateway.verifyCode(email: sentTo, code: code, purpose: purpose)
      }
    } catch {
      if ownsSwitchFlag { dependencies.markSwitch(false) }
      return publish(classifyVerification(error))
    }
    kinds.save(.email)
    let name = Self.validDisplayName(displayName)
    if purpose == .link {
      await resume(&sync)
      dependencies.sessionDidChange()
      if let name { await writeDisplayName(name) }
      outcome = .linked
      phase = .done
      return
    }
    phase = .merging
    var added = 0
    if fromEmailAccount, verified.accountId != dependencies.previousAccountId() {
      // D'un compte e-mail à un autre : les données de l'ancien restent chez lui, sur le serveur. L'appareil est purgé
      // avant que la synchro reprenne, sinon elles partiraient au nouveau compte.
      do {
        try await dependencies.switchAccount(verified.accountId)
        dependencies.markSwitch(false)
      } catch {
        Self.logger.error("Changement de compte impossible : \(String(describing: error), privacy: .private)")
        // Retour à l'attente d'une connexion, sans rien renvoyer. Session encore là : la purge reste due.
        do {
          try await gateway.signOut()
          dependencies.markSwitch(false)
        } catch {
          sync = .heldForPurge
        }
        phase = .enterEmail
        self.purpose = nil
        self.sentTo = nil
        codeSentAt = nil
        return publish(.unknown)
      }
    } else {
      if fromEmailAccount { dependencies.markSwitch(false) }
      // Compte existant : les listes du téléphone y sont ajoutées par la passe qui suit (`AccountRekey`).
      added = dependencies.resendableLists(verified.accountId)
    }
    await resume(&sync)
    dependencies.sessionDidChange()
    await dependencies.synchronize()
    if let token = verified.previousAnonymousToken {
      do {
        try await withTimeout(Self.timeout) { try await gateway.deleteAccount(accessToken: token) }
      } catch {
        // Sans conséquence : la purge des comptes anonymes inactifs le supprimera (#68, 365 jours).
        Self.logger.notice("Ancien compte anonyme gardé : \(AuthBootstrap.publicCode(of: error), privacy: .public)")
      }
    }
    var known = try? await withTimeout(Self.timeout) { try await gateway.displayName() }
    if known == nil, let name {
      await writeDisplayName(name)
      known = name
    }
    outcome = .signedIn(displayName: known, addedLists: added)
    phase = .done
  }

  private func resume(_ sync: inout SyncHold) async {
    guard sync == .suspended else { return }
    sync = .resumed
    await dependencies.resumeSync()
  }

  // MARK: - Outils

  private func sendCode(to address: String) async {
    // Compte de revue des stores (#149) : aucune requête, aucun e-mail, même pour « Renvoyer le code ». Rien ne part :
    // le réseau n'est vérifié qu'avec le code.
    if ReviewAccount.matches(address) {
      error = nil
      return codeSent(to: address, purpose: .review)
    }
    guard dependencies.isOnline() else { return publish(.offline) }
    isWorking = true
    error = nil
    defer { isWorking = false }
    do {
      // Compte anonyme : liaison, sauf si le code en cours est déjà un code de connexion (renvoi).
      let next = canLink && purpose != .signIn ? try await linkOrSignIn(address) : try await signIn(address)
      codeSent(to: address, purpose: next)
    } catch {
      publish(classifyRequest(error))
    }
  }

  /// Passage à la saisie du code.
  private func codeSent(to address: String, purpose next: EmailCodePurpose) {
    purpose = next
    sentTo = address
    codeSentAt = dependencies.now()
    phase = .enterCode
  }

  /// Liaison au compte de l'appareil ; adresse déjà prise : connexion au compte existant (vecteur `010`).
  private func linkOrSignIn(_ address: String) async throws -> EmailCodePurpose {
    let gateway = gateway
    do {
      try await withTimeout(Self.timeout) { try await gateway.linkEmail(address) }
      return .link
    } catch let failure as AuthRequestError {
      switch SyncDecisions.linkEmailNextStep(status: failure.status, errorCode: failure.code) {
      case .signInExisting: return try await signIn(address)
      case .rateLimited: throw AccountLinkError.rateLimited
      case .enterLinkCode, .retry: throw failure
      }
    }
  }

  private func signIn(_ address: String) async throws -> EmailCodePurpose {
    let gateway = gateway
    try await withTimeout(Self.timeout) { try await gateway.signInWithEmail(address) }
    return .signIn
  }

  private func writeDisplayName(_ name: String) async {
    let gateway = gateway
    do {
      try await withTimeout(Self.timeout) { try await gateway.setDisplayName(name) }
    } catch {
      // Le prénom se corrige dans À propos → Compte.
      Self.logger.notice("Prénom non enregistré : \(AuthBootstrap.publicCode(of: error), privacy: .public)")
    }
  }

  private func publish(_ error: AccountLinkError) {
    self.error = error
    errorRevision += 1
  }

  /// Codes GoTrue d'une adresse refusée. `otp_disabled` : pas de compte pour cette adresse, et on ne peut que s'y
  /// connecter.
  private static let invalidEmailCodes: Set<String> = [
    "email_address_invalid", "validation_failed", "otp_disabled", "email_address_not_authorized", "signup_disabled",
  ]

  private func classifyRequest(_ error: any Error) -> AccountLinkError {
    switch error {
    case let error as AccountLinkError: return error
    case let error as AuthRequestError:
      if error.status == 429 { return .rateLimited }
      return error.code.map(Self.invalidEmailCodes.contains) == true ? .invalidEmail : .unknown
    case let error as RemoteError: return error == .network || error == .notSent ? .offline : .unknown
    default: return .unknown
    }
  }

  /// GoTrue répond `otp_expired` à un code faux comme à un code expiré : l'âge du code les distingue.
  private func classifyVerification(_ error: any Error) -> AccountLinkError {
    switch error {
    case let error as AuthRequestError:
      if error.status == 429 { return .rateLimited }
      guard (400..<500).contains(error.status) else { return .unknown }
      // Le code de revue (#149) n'expire jamais : un refus est toujours un code faux.
      guard purpose != .review else { return .invalidCode }
      let age = codeSentAt.map { dependencies.now().timeIntervalSince($0) } ?? 0
      return age >= Self.codeLifetime ? .expiredCode : .invalidCode
    case let error as RemoteError: return error == .network || error == .notSent ? .offline : .unknown
    default: return .unknown
    }
  }
}
