import Foundation
import OSLog
import Observation

/// Échec d'une suppression de compte, tel que l'écran l'annonce. Mêmes cas sur Android.
nonisolated enum AccountDeletionError: Error, Equatable, Sendable {
  /// Pas de réseau, ou requête jamais partie : rien n'a été touché.
  case offline
  /// Refus définitif du serveur : rien n'a été effacé, la synchronisation a repris.
  case refused
  /// Issue inconnue (réponse perdue, serveur indisponible) et compte toujours présent, ou impossible à vérifier.
  /// Le drapeau reste : « Réessayer » ou « Annuler ».
  case unknown
}

extension RemoteError {
  /// Suppression du compte : refus sans doute possible sur l'issue (requête refusée, fonction absente, 4xx sans
  /// code). Le reste (réseau, 5xx, `55P03`, `57014`, session refusée) laisse un doute, levé par
  /// `confirmAccountDeleted`.
  nonisolated var isDefinitiveDeletionRefusal: Bool {
    switch self {
    case .rejected, .constraint: true
    case .server: isCappedClientFailure
    default: false
    }
  }
}

/// Ce que la suppression demande au reste de l'app (#68 §5.3, §5.5).
protocol AccountDeletionHost: AnyObject {
  /// Étape 1 : plus aucune passe de synchronisation, celle en cours comprise, ni tâche d'arrière-plan.
  func suspendSync() async
  /// Suppression refusée ou abandonnée : la synchronisation reprend.
  func resumeSync()
  /// Avant la purge : le moteur est arrêté pour de bon, aucune connexion tardive ne doit le relancer.
  func stopSync() async
  /// Étape 2 : Live Activities retirées tout de suite, mode courses fermé sans clore la visite.
  func endShopping()
  /// Étape 5, après le message : état de l'app reconstruit sur le nouveau compte, synchronisation replanifiée.
  func restart()
}

/// Déroulé de la suppression du compte et de ses données (#68 §5.3). Chaque étape peut être rejouée : un arrêt du
/// processus laisse le drapeau `account.deletion`, et `resumeIfNeeded` reprend au lancement suivant.
///
/// 1. drapeau, synchronisation suspendue ; 2. Live Activities et mode courses fermés ; 3. RPC (15 s), doute levé
/// par `confirmAccountDeleted` ; 4. purge de l'appareil, déconnexion locale ; 5. drapeau effacé, puis
/// `ensureSession`.
///
/// Seules trois réponses de GoTrue prouvent la suppression (`accountGone`). Après un doute, rien n'efface le
/// drapeau sans que le serveur ait confirmé que le compte existe toujours : sinon la synchronisation reprise
/// renverrait toutes les données vers un nouveau compte.
@Observable
final class AccountDeletion {
  nonisolated enum Status: Equatable, Sendable {
    case idle
    /// Voile « Suppression… », non annulable.
    case deleting
    case failed(AccountDeletionError)
    /// Compte supprimé sur le serveur (ou build sans serveur) et appareil purgé. `acknowledge()` reconstruit l'app.
    case deleted
    /// Pas de session sur l'appareil, ou celle d'un autre compte que celui à supprimer : le compte serveur est hors
    /// d'atteinte. L'appareil est purgé ; le serveur supprimera le compte après 365 jours sans utilisation.
    case deletedFromDevice
  }

  /// Points de passage, dans l'ordre. Les tests y simulent un arrêt du processus.
  nonisolated enum Step: Equatable, Sendable {
    case flagged
    case syncSuspended
    case shoppingEnded
    case serverDeleted
    case purge(LocalDataPurge.Step)
    case signedOut
    case flagCleared
    case sessionCreated
  }

  /// Limite de chaque appel au serveur.
  static let timeout = Duration.seconds(15)
  /// « Annuler » attend ce délai après le dernier envoi de la RPC : une requête en retard pourrait encore
  /// supprimer le compte après que le serveur a dit qu'il existait.
  static let cancelDelay: TimeInterval = 30
  private static let logger = Logger(subsystem: "app.parcourses", category: "account")

  private(set) var status = Status.idle
  /// Change à chaque issue publiée, même identique à la précédente : l'écran la présente à nouveau.
  private(set) var revision = 0
  /// « Annuler » refusé pour l'instant (envoi trop récent, ou serveur muet) : « Réessayez dans un instant ».
  private(set) var isCancelDeferred = false
  /// Câblé par l'app après la construction : l'hôte possède la suppression.
  @ObservationIgnored weak var host: (any AccountDeletionHost)?

  private let gateway: (any RemoteGateway)?
  private let flags: any AccountDeletionFlagStore
  private let purge: LocalDataPurge
  private let isOnline: () -> Bool
  private let hasOpenVisit: () -> Bool
  private let timeout: Duration
  private let now: () -> Date
  /// Demande du temps d'exécution au système ; renvoie de quoi le rendre.
  private let beginBackgroundWork: () -> (() -> Void)
  private let checkpoint: (Step) throws -> Void
  /// Dernier envoi de la RPC par ce processus.
  @ObservationIgnored private var lastServerAttempt: Date?

  /// `gateway` à `nil` : build sans Supabase, la suppression ne purge que l'appareil (#68 §5.7).
  init(
    gateway: (any RemoteGateway)?, flags: any AccountDeletionFlagStore, purge: LocalDataPurge,
    isOnline: @escaping () -> Bool, hasOpenVisit: @escaping () -> Bool = { false },
    timeout: Duration = AccountDeletion.timeout, now: @escaping () -> Date = { .now },
    beginBackgroundWork: @escaping () -> (() -> Void) = { {} },
    checkpoint: @escaping (Step) throws -> Void = { _ in }
  ) {
    self.gateway = gateway
    self.flags = flags
    self.purge = purge
    self.isOnline = isOnline
    self.hasOpenVisit = hasOpenVisit
    self.timeout = timeout
    self.now = now
    self.beginBackgroundWork = beginBackgroundWork
    self.checkpoint = checkpoint
  }

  /// Faux dans un build sans Supabase : il n'y a rien à supprimer sur nos serveurs.
  var deletesServerData: Bool { gateway != nil }

  /// Une visite est ouverte : la confirmation prévient que les courses seront interrompues.
  var interruptsShopping: Bool { hasOpenVisit() }

  /// Une suppression a commencé et n'est pas finie (drapeau présent).
  var isPending: Bool { flags.isDeletionPending }

  /// Suppression demandée par la personne. Réseau exigé avant de toucher à quoi que ce soit.
  func delete() async {
    guard status == .idle || status == .failed(.offline) || status == .failed(.refused) else { return }
    if gateway != nil, !isOnline() {
      publish(.failed(.offline))
      return
    }
    status = .deleting
    await run {
      // Le drapeau d'abord : le compte de la session y est ajouté avant le premier envoi (`finish`).
      self.flags.save(AccountDeletionFlag(accountId: nil, phase: .requested))
      try self.halt(.flagged)
      try await self.prepare()
      try await self.finish()
    }
  }

  /// Au lancement, drapeau présent : le processus a été arrêté en cours de route. Ni synchronisation ni
  /// `ensureSession` avant la fin. Avec la session du compte à supprimer, la RPC est rejouée (idempotente) ; sans
  /// elle, ou avec celle d'un autre compte, purge de l'appareil seulement.
  func resumeIfNeeded() async {
    guard flags.isDeletionPending, status != .deleting else { return }
    status = .deleting
    await run {
      try await self.prepare()
      try await self.finish()
    }
  }

  /// Après une issue inconnue : rejoue la suppression, avec le même drapeau.
  func retry() async {
    guard status == .failed(.unknown) else { return }
    status = .deleting
    await run { try await self.finish() }
  }

  /// Après une issue inconnue : abandon, seulement si la RPC est partie depuis au moins `cancelDelay` et que le
  /// serveur confirme, maintenant, que le compte existe. Preuve de suppression : la purge se fait. Sans session sur
  /// l'appareil, aucune preuve n'est possible : la personne garde ses données. Sinon : « Réessayez dans un instant ».
  func cancel() async {
    guard status == .failed(.unknown) else { return }
    guard let gateway else {
      // Sans serveur, l'issue inconnue vient d'une écriture locale : « Annuler » garde ce qui reste.
      keepData()
      return
    }
    if let lastServerAttempt, now().timeIntervalSince(lastServerAttempt) < Self.cancelDelay {
      publish(.failed(.unknown), cancelDeferred: true)
      return
    }
    status = .deleting
    await run {
      let local: UUID?
      do {
        local = try await gateway.localSessionAccountId()
      } catch {
        self.publish(.failed(.unknown), cancelDeferred: true)
        return
      }
      guard local != nil else {
        self.keepData()
        return
      }
      switch await self.verifyDeletion(gateway) {
      case .some(false):
        self.keepData()
      case .some(true):
        try await self.purgeAndSignIn(outcome: .deleted)
      case .none:
        self.publish(.failed(.unknown), cancelDeferred: true)
      }
    }
  }

  /// Message lu. Après une suppression réussie, l'app repart sur le nouveau compte.
  func acknowledge() {
    switch status {
    case .deleted, .deletedFromDevice:
      publish(.idle)
      host?.restart()
    case .failed(.offline), .failed(.refused):
      publish(.idle)
    case .idle, .deleting, .failed(.unknown):
      break
    }
  }

  // MARK: - Étapes

  /// Arrêt simulé (tests) : rien de ce qui suit n'est fait, comme si le processus avait été tué.
  private struct Halted: Error {}

  private func halt(_ step: Step) throws {
    do {
      try checkpoint(step)
    } catch {
      throw Halted()
    }
  }

  private func publish(_ status: Status, cancelDeferred: Bool = false) {
    isCancelDeferred = cancelDeferred
    self.status = status
    revision += 1
  }

  /// Le système laisse finir l'étape serveur et la purge si l'app passe en arrière-plan. À l'expiration, le
  /// drapeau reste : la suppression reprend au lancement suivant.
  private func run(_ work: () async throws -> Void) async {
    let end = beginBackgroundWork()
    defer { end() }
    do {
      try await work()
    } catch is Halted {
      return
    } catch {
      // Écriture locale impossible : le drapeau reste, « Réessayer » reprend la purge.
      Self.logger.error("Suppression interrompue : \(String(describing: error), privacy: .private)")
      publish(.failed(.unknown))
    }
  }

  /// Étapes 1 et 2, rejouables.
  private func prepare() async throws {
    await host?.suspendSync()
    try halt(.syncSuspended)
    host?.endShopping()
    try halt(.shoppingEnded)
  }

  /// Étapes 3 à 5. Un refus ou un envoi impossible n'arrêtent la suppression qu'au premier envoi de la RPC ; ensuite,
  /// un envoi précédent a peut-être abouti, et seul le serveur peut dire que le compte existe encore.
  private func finish() async throws {
    var flag = flags.load() ?? AccountDeletionFlag(accountId: nil, phase: .requested, rpcAttempted: true)
    guard let gateway, flag.phase == .requested else {
      try await purgeAndSignIn(outcome: .deleted)
      return
    }
    // Keychain illisible : doute, jamais refus.
    let local: UUID?
    do {
      local = try await gateway.localSessionAccountId()
    } catch {
      publish(.failed(.unknown))
      return
    }
    // Compte pas encore noté (arrêt juste après le drapeau) : aucun compte n'a pu être créé depuis, la session est
    // la sienne.
    if flag.accountId == nil, !flag.rpcAttempted, let local {
      flag.accountId = local
      flags.save(flag)
    }
    // Sans session, ou avec celle d'un autre compte, le compte serveur est hors d'atteinte : appareil seulement.
    guard let local, local == flag.accountId else {
      try await purgeAndSignIn(outcome: .deletedFromDevice)
      return
    }

    let isFirstAttempt = !flag.rpcAttempted
    flag.rpcAttempted = true
    flags.save(flag)
    lastServerAttempt = now()
    switch await deleteOnServer(gateway) {
    case .deleted:
      break
    case .failed(let failure) where isFirstAttempt:
      abandon(failure)
      return
    case .failed(let failure):
      switch await verifyDeletion(gateway) {
      case .some(true):
        break
      case .some(false):
        abandon(failure)
        return
      case .none:
        publish(.failed(.unknown))
        return
      }
    case .doubtful:
      guard await verifyDeletion(gateway) == true else {
        publish(.failed(.unknown))
        return
      }
    }
    flag.phase = .serverDeleted
    flags.save(flag)
    try halt(.serverDeleted)
    try await purgeAndSignIn(outcome: .deleted)
  }

  /// Annulation : la personne garde ses données, la synchronisation reprend.
  private func keepData() {
    flags.clear()
    host?.resumeSync()
    publish(.idle)
  }

  /// Rien n'a été supprimé, c'est certain : le drapeau part et la synchronisation reprend.
  private func abandon(_ failure: AccountDeletionError) {
    flags.clear()
    host?.resumeSync()
    publish(.failed(failure))
  }

  private enum ServerOutcome {
    case deleted
    case failed(AccountDeletionError)
    case doubtful
  }

  private func deleteOnServer(_ gateway: any RemoteGateway) async -> ServerOutcome {
    do {
      try await withTimeout(timeout) { try await gateway.deleteAccount() }
      return .deleted
    } catch {
      let remote = error as? RemoteError ?? .unexpected
      Self.logger.notice("Suppression du compte sans réponse nette : \(String(describing: remote), privacy: .public)")
      switch remote {
      case .accountGone: return .deleted
      case .notSent: return .failed(.offline)
      default: return remote.isDefinitiveDeletionRefusal ? .failed(.refused) : .doubtful
      }
    }
  }

  /// `true` : GoTrue prouve que le compte n'existe plus. `false` : le compte existe. `nil` : impossible de le savoir.
  private func verifyDeletion(_ gateway: any RemoteGateway) async -> Bool? {
    try? await withTimeout(timeout) { try await gateway.confirmAccountDeleted() }
  }

  /// Étapes 4 et 5. Le drapeau part en dernier : tant qu'il existe, aucun compte ne peut être créé.
  private func purgeAndSignIn(outcome: Status) async throws {
    await host?.stopSync()
    try purge.run { try halt(.purge($0)) }
    try await gateway?.signOutLocally()
    try halt(.signedOut)
    flags.clear()
    try halt(.flagCleared)
    if let gateway {
      // Marqueurs vides : le nouveau compte est adopté sans reprise. Un échec ici n'empêche rien, la connexion
      // sera retentée au lancement de l'app reconstruite.
      do {
        _ = try await withTimeout(timeout) { try await gateway.ensureSession(captchaToken: nil) }
      } catch {
        Self.logger.notice("Nouveau compte reporté : \(String(describing: error), privacy: .private)")
      }
    }
    try halt(.sessionCreated)
    publish(outcome)
  }
}

/// Lève `RemoteError.network` au-delà de `duration` : une réponse perdue se traite comme une coupure.
nonisolated func withTimeout<T: Sendable>(
  _ duration: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw RemoteError.network
    }
    defer { group.cancelAll() }
    guard let value = try await group.next() else { throw RemoteError.network }
    return value
  }
}
