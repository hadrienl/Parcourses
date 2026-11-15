import Foundation
import Network
import Observation

/// Lien d'invitation ouvert dans l'app : le jeton reste en mémoire, jamais écrit sur disque (#87 §1.3).
struct OpenedInvitation: Identifiable, Equatable {
  let id = UUID()
  let token: String
}

/// État du partage commun aux écrans (#87, lot 87.4) : invitations reçues, lien ouvert, feuille « Partager » ouverte,
/// réseau, changements d'accès à annoncer, et le canal temps réel.
@Observable
final class SharingCenter {
  struct Dependencies {
    /// Compte e-mail connecté : seul à pouvoir inviter, accepter, et à recevoir des signaux.
    var isEmailAccount: () -> Bool = { false }
    /// Adresse du compte, pour l'avertissement « autre adresse ».
    var accountEmail: () -> String? = { nil }
    /// Passe complète, attendue : la liste acceptée descend avant de s'ouvrir.
    var synchronize: () async -> Void = {
      // Sans moteur de synchro.
    }
    /// Descente demandée par un signal, sans attendre.
    var requestPull: () -> Void = {
      // Sans moteur de synchro.
    }
    var listExists: (UUID) -> Bool = { _ in false }
    /// Retire une liste de l'appareil sans rien envoyer (« Quitter la liste »).
    var forgetList: (UUID) -> Void = { _ in
      // Sans stockage.
    }
    /// Mon compte, pour les marques d'auteur et « vous ».
    var accountId: () -> UUID? = { nil }
    /// Signal `items` qui n'est probablement que l'écho de ma dernière écriture (#87 §6.6) : temps restant de la
    /// fenêtre, `nil` sinon.
    var echoDelay: (RealtimeSignal) -> TimeInterval? = { _ in nil }
  }

  /// Invitations adressées à mon adresse (`my_invitations`), la plus récente d'abord.
  private(set) var invitations: [ReceivedInvitation] = []
  /// Lien d'invitation ouvert, présenté en feuille par la racine.
  var openedLink: OpenedInvitation?
  /// Liste dont la feuille « Partager » ou « Membres » est ouverte.
  var openSheetListId: UUID?
  /// Change à chaque signal `members` / `invitations` sur la liste de la feuille ouverte : elle relit `list_sharing`.
  private(set) var sharingRevision = 0
  /// Réseau disponible (bandeau hors ligne, actions qui demandent une connexion).
  private(set) var isOnline = true
  /// Dernier changement d'accès par liste : la liste ouverte affiche sa bannière.
  private(set) var accessChanges: [UUID: SharingAccessChange] = [:]
  /// Listes retirées de l'appareil, à annoncer dans Mes listes.
  private(set) var removedLists: [SharingAccessChange] = []

  @ObservationIgnored private(set) var signals: RealtimeSignals?
  @ObservationIgnored let gateway: (any RemoteGateway)?
  @ObservationIgnored let links: InvitationLinks
  @ObservationIgnored let dependencies: Dependencies
  @ObservationIgnored private var network: NetworkWatcher?
  @ObservationIgnored private var accessObserver: NotificationToken?

  init(
    gateway: (any RemoteGateway)?, transport: (any RealtimeTransport)?, links: InvitationLinks = InvitationLinks(),
    dependencies: Dependencies = Dependencies(), monitorsNetwork: Bool = true
  ) {
    self.gateway = gateway
    self.links = links
    self.dependencies = dependencies
    let isEmail = dependencies.isEmailAccount
    signals = RealtimeSignals(
      transport: transport,
      dependencies: RealtimeSignals.Dependencies(
        accountId: { try? await gateway?.localSessionAccountId() },
        isEmailAccount: isEmail,
        isSharingSheetOpen: { [weak self] listId in listId != nil && self?.openSheetListId == listId },
        pull: dependencies.requestPull,
        reloadInvitations: { [weak self] in Task { await self?.loadInvitations() } },
        reloadSharing: { [weak self] _ in self?.sharingRevision += 1 }, echoDelay: dependencies.echoDelay))
    if monitorsNetwork {
      network = NetworkWatcher { [weak self] online in
        Task { @MainActor in self?.isOnline = online }
      }
    }
    accessObserver = NotificationToken(
      NotificationCenter.default.addObserver(forName: .sharingAccessDidChange, object: nil, queue: .main) {
        [weak self] notification in
        guard let change = notification.object as? SharingAccessChange else { return }
        MainActor.assumeIsolated { self?.record(change) }
      })
  }

  /// Un compte e-mail peut inviter, accepter et gérer les membres (#87 §1).
  var isEmailAccount: Bool { dependencies.isEmailAccount() }
  var isAvailable: Bool { gateway != nil }

  // MARK: - Cycle de vie

  /// Premier plan, ou compte relu : canal temps réel et invitations.
  func foreground() async {
    await signals?.foreground()
    await loadInvitations()
  }

  func background() async {
    await signals?.background()
  }

  /// Changement de phase de la scène, posé sans attendre : un canal ne s'ouvre pas en arrière-plan (#87 §6.6).
  func scenePhaseChanged(isActive: Bool) {
    if isActive { signals?.enteredForeground() } else { signals?.enteredBackground() }
  }

  // MARK: - Invitations reçues

  /// `my_invitations`, pour un compte e-mail seulement. Hors ligne, la liste connue reste.
  func loadInvitations() async {
    guard let gateway, isEmailAccount else {
      invitations = []
      return
    }
    guard let rows = try? await gateway.myInvitations() else { return }
    invitations = rows
  }

  /// Invitation traitée (acceptée, refusée) : elle quitte la liste sans attendre la relecture.
  func dropInvitation(_ id: UUID) {
    invitations.removeAll { $0.id == id }
  }

  // MARK: - Liens

  /// Lien ouvert dans l'app (schéma, ou lien universel livré par `onOpenURL`) : vrai s'il s'agit d'une invitation,
  /// présentée en feuille. Un second lien remplace le premier ; le même lien livré deux fois (`onOpenURL` puis
  /// `onContinueUserActivity`) garde la feuille déjà présentée.
  @discardableResult
  func open(url: URL) -> Bool {
    guard let token = links.token(in: url) else { return false }
    if openedLink?.token != token { openedLink = OpenedInvitation(token: token) }
    return true
  }

  /// Lien universel (`https://<hôte>/i/#<jeton>`, #87 lot 87.7) livré par `onContinueUserActivity` : même carte que le
  /// schéma. Toute autre activité est ignorée.
  @discardableResult
  func open(userActivity: NSUserActivity) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else {
      return false
    }
    return open(url: url)
  }

  func makeCard(for invitation: ReceivedInvitation) -> InvitationCardModel {
    InvitationCardModel(source: .received(invitation), center: self)
  }

  func makeCard(token: String) -> InvitationCardModel {
    InvitationCardModel(source: .link(token: token), center: self)
  }

  func makeShareModel(listId: UUID, listName: String) -> ShareListModel {
    ShareListModel(listId: listId, listName: listName, center: self)
  }

  // MARK: - Accès

  func record(_ change: SharingAccessChange) {
    accessChanges[change.listId] = change
    if change.kind == .removed { removedLists.append(change) }
  }

  /// La bannière a été lue (« Compris »).
  func acknowledgeChange(listId: UUID) {
    accessChanges[listId] = nil
  }

  func acknowledgeRemoval(_ change: SharingAccessChange) {
    removedLists.removeAll { $0 == change }
  }
}

/// Suit le réseau (`NWPathMonitor`) tant qu'il vit : arrêté avec son propriétaire.
nonisolated final class NetworkWatcher: Sendable {
  private let monitor = NWPathMonitor()

  init(onChange: @escaping @Sendable (Bool) -> Void) {
    monitor.pathUpdateHandler = { path in onChange(path.status == .satisfied) }
    monitor.start(queue: DispatchQueue(label: "app.parcourses.sharing.network"))
  }

  deinit {
    monitor.cancel()
  }
}

/// Observateur de `NotificationCenter`, retiré avec son propriétaire.
nonisolated final class NotificationToken: @unchecked Sendable {
  private let token: any NSObjectProtocol

  init(_ token: any NSObjectProtocol) {
    self.token = token
  }

  deinit {
    NotificationCenter.default.removeObserver(token)
  }
}
