import Foundation
import OSLog
import Observation

/// Échec d'une suppression de compte, tel que l'écran l'annonce. Mêmes cas sur Android.
nonisolated enum AccountDeletionError: Error, Equatable, Sendable {
  /// Pas de réseau au moment de commencer : rien n'a été touché.
  case offline
  /// Refus définitif du serveur : rien n'a été effacé, la synchronisation a repris.
  case refused
  /// Issue inconnue (réponse perdue, serveur indisponible) et compte toujours présent, ou impossible à vérifier.
  /// Le drapeau reste : « Réessayer » ou « Annuler ».
  case unknown
}

extension RemoteError {
  /// Suppression du compte : refus sans doute possible sur l'issue (requête refusée, fonction absente, 4xx sans
  /// code). Le reste (réseau, 5xx, `55P03`, `57014`, session absente) laisse un doute, levé par `verifySession`.
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
  /// Étape 2 : Live Activities retirées tout de suite, mode courses fermé sans clore la visite.
  func endShopping()
  /// Étape 5, après le message : état de l'app reconstruit sur le nouveau compte, synchronisation replanifiée.
  func restart()
}

/// Déroulé de la suppression du compte et de ses données (#68 §5.3). Chaque étape peut être rejouée : un arrêt du
/// processus laisse le drapeau `account.deletion`, et `resumeIfNeeded` reprend au lancement suivant.
///
/// 1. drapeau, synchronisation suspendue ; 2. Live Activities et mode courses fermés ; 3. RPC (15 s), doute levé
/// par `verifySession` ; 4. purge de l'appareil, déconnexion locale ; 5. drapeau effacé, puis `ensureSession`.
@Observable
final class AccountDeletion {
  nonisolated enum Status: Equatable, Sendable {
    case idle
    /// Voile « Suppression… », non annulable.
    case deleting
    case failed(AccountDeletionError)
    /// « Vos données ont été supprimées. » ; `acknowledge()` reconstruit l'app.
    case deleted
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
  private static let logger = Logger(subsystem: "app.parcourses", category: "account")

  private(set) var status = Status.idle
  /// Câblé par l'app après la construction : l'hôte possède la suppression.
  @ObservationIgnored weak var host: (any AccountDeletionHost)?

  private let gateway: (any RemoteGateway)?
  private let flags: any AccountDeletionFlagStore
  private let purge: LocalDataPurge
  private let isOnline: () -> Bool
  private let hasOpenVisit: () -> Bool
  private let timeout: Duration
  private let checkpoint: (Step) throws -> Void

  /// `gateway` à `nil` : build sans Supabase, la suppression ne purge que l'appareil (#68 §5.7).
  init(
    gateway: (any RemoteGateway)?, flags: any AccountDeletionFlagStore, purge: LocalDataPurge,
    isOnline: @escaping () -> Bool, hasOpenVisit: @escaping () -> Bool = { false },
    timeout: Duration = AccountDeletion.timeout, checkpoint: @escaping (Step) throws -> Void = { _ in }
  ) {
    self.gateway = gateway
    self.flags = flags
    self.purge = purge
    self.isOnline = isOnline
    self.hasOpenVisit = hasOpenVisit
    self.timeout = timeout
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
      status = .failed(.offline)
      return
    }
    status = .deleting
    await perform {
      // Lecture locale si le jeton est encore valable. Sans session, rien à supprimer côté serveur.
      let accountId = try? await self.gateway?.sessionAccountId()
      self.flags.save(AccountDeletionFlag(accountId: accountId, phase: .requested))
      try self.halt(.flagged)
      try await self.prepare()
      try await self.finish(phase: .requested)
    }
  }

  /// Au lancement, drapeau présent : le processus a été arrêté en cours de route. Ni synchronisation ni
  /// `ensureSession` avant la fin. Avec une session, la RPC est rejouée (idempotente) ; sans session, purge directe.
  func resumeIfNeeded() async {
    guard flags.isDeletionPending, status != .deleting else { return }
    status = .deleting
    await perform {
      try await self.prepare()
      try await self.finish(phase: self.flags.load()?.phase ?? .requested, checkSession: true)
    }
  }

  /// Après une issue inconnue : rejoue la suppression, avec le même drapeau.
  func retry() async {
    guard status == .failed(.unknown) else { return }
    status = .deleting
    await perform {
      try await self.finish(phase: self.flags.load()?.phase ?? .requested, checkSession: true)
    }
  }

  /// Après une issue inconnue : abandon, seulement si le serveur confirme que le compte existe toujours. S'il a
  /// disparu, la suppression a eu lieu et la purge se fait ; sans réponse, rien ne change.
  func cancel() async {
    guard status == .failed(.unknown) else { return }
    guard let gateway else {
      // Sans serveur, aucune issue n'est inconnue : la purge locale reprend.
      await retry()
      return
    }
    status = .deleting
    await perform {
      switch await self.verifyDeletion(gateway) {
      case .some(false):
        self.flags.clear()
        self.host?.resumeSync()
        self.status = .idle
      case .some(true):
        try await self.purgeAndSignIn()
      case .none:
        self.status = .failed(.unknown)
      }
    }
  }

  /// Message lu. Après une suppression réussie, l'app repart sur le nouveau compte.
  func acknowledge() {
    switch status {
    case .deleted:
      status = .idle
      host?.restart()
    case .failed(.offline), .failed(.refused):
      status = .idle
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

  private func perform(_ work: () async throws -> Void) async {
    do {
      try await work()
    } catch is Halted {
      return
    } catch {
      // Écriture locale impossible : le drapeau reste, « Réessayer » reprend la purge.
      Self.logger.error("Suppression interrompue : \(String(describing: error), privacy: .private)")
      status = .failed(.unknown)
    }
  }

  /// Étapes 1 et 2, rejouables.
  private func prepare() async throws {
    await host?.suspendSync()
    try halt(.syncSuspended)
    host?.endShopping()
    try halt(.shoppingEnded)
  }

  /// Étapes 3 à 5. `checkSession` : reprise, où une session absente prouve qu'il n'y a plus rien à atteindre.
  private func finish(phase: AccountDeletionPhase, checkSession: Bool = false) async throws {
    if phase == .requested, let gateway {
      if checkSession, await hasNoSession(gateway) {
        // Soit le serveur a déjà supprimé le compte, soit la session était perdue et le compte hors d'atteinte
        // (purgé après 365 jours d'inactivité).
        try await purgeAndSignIn()
        return
      }
      switch await deleteOnServer(gateway) {
      case .deleted:
        break
      case .refused:
        flags.clear()
        host?.resumeSync()
        status = .failed(.refused)
        return
      case .doubtful:
        guard await verifyDeletion(gateway) == true else {
          status = .failed(.unknown)
          return
        }
      }
      var flag = flags.load() ?? AccountDeletionFlag(accountId: nil, phase: .requested)
      flag.phase = .serverDeleted
      flags.save(flag)
      try halt(.serverDeleted)
    }
    try await purgeAndSignIn()
  }

  private enum ServerOutcome {
    case deleted
    case refused
    case doubtful
  }

  private func deleteOnServer(_ gateway: any RemoteGateway) async -> ServerOutcome {
    do {
      try await withTimeout(timeout) { try await gateway.deleteAccount() }
      return .deleted
    } catch {
      let remote = error as? RemoteError ?? .unexpected
      Self.logger.notice("Suppression du compte sans réponse nette : \(String(describing: remote), privacy: .public)")
      return remote.isDefinitiveDeletionRefusal ? .refused : .doubtful
    }
  }

  /// `true` : compte introuvable ou session disparue, la suppression a eu lieu. `false` : le compte existe.
  /// `nil` : impossible de le savoir (réseau, Keychain verrouillé).
  private func verifyDeletion(_ gateway: any RemoteGateway) async -> Bool? {
    do {
      try await withTimeout(timeout) { try await gateway.verifySession() }
      return false
    } catch RemoteError.unauthorized {
      return true
    } catch {
      return nil
    }
  }

  private func hasNoSession(_ gateway: any RemoteGateway) async -> Bool {
    do {
      _ = try await withTimeout(timeout) { try await gateway.sessionAccountId() }
      return false
    } catch RemoteError.unauthorized {
      return true
    } catch {
      // Session présente mais injoignable : la RPC dira le reste.
      return false
    }
  }

  /// Étapes 4 et 5. Le drapeau part en dernier : tant qu'il existe, aucun compte ne peut être créé.
  private func purgeAndSignIn() async throws {
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
    status = .deleted
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
