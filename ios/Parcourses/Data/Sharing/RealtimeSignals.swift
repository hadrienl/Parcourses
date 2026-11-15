import Foundation
import OSLog

/// Signaux temps réel du compte (#87 §6.2, §6.5, §6.6) : un canal privé `user:<uid>` par appareil, seulement pour un
/// compte e-mail, ouvert au premier plan et fermé en arrière-plan. Les signaux sont regroupés sur 300 ms, puis
/// `SharingDecisions.signalActions` dit quoi faire. À chaque (re)connexion du canal, une descente : les signaux manqués
/// ne sont pas rejoués. Le temps réel n'est qu'un réveil : sans lui, tout marche comme avant.
@MainActor
final class RealtimeSignals {
  struct Dependencies {
    /// Compte de la session, sans appel au serveur.
    var accountId: () async -> UUID? = { nil }
    /// Seul un compte e-mail connecté ouvre un canal.
    var isEmailAccount: () -> Bool = { false }
    /// La feuille « Partager » de cette liste est-elle ouverte ?
    var isSharingSheetOpen: (UUID?) -> Bool = { _ in false }
    var pull: () -> Void = {
      // Sans moteur de synchro.
    }
    var reloadInvitations: () -> Void = {
      // Sans écran d'invitations.
    }
    var reloadSharing: (UUID) -> Void = { _ in
      // Sans feuille « Partager ».
    }
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  }

  /// Regroupement des signaux (§6.2).
  static let groupingDelay: Duration = .milliseconds(300)
  /// Canal refusé ou coupé sans reprise : nouvel essai tant que l'app est au premier plan.
  static let retryDelay: Duration = .seconds(30)

  private static let logger = Logger(subsystem: "app.parcourses", category: "realtime")

  private let transport: (any RealtimeTransport)?
  private let dependencies: Dependencies
  private var listener: Task<Void, Never>?
  private var openedFor: UUID?
  private var pending: [RealtimeSignal] = []
  private var flushTask: Task<Void, Never>?
  /// Fermeture en cours : une ouverture attend qu'elle soit finie.
  private var closing: Task<Void, Never>?

  /// Canal ouvert (ou en cours d'ouverture) pour ce compte.
  var isOpen: Bool { listener != nil }

  init(transport: (any RealtimeTransport)?, dependencies: Dependencies = Dependencies()) {
    self.transport = transport
    self.dependencies = dependencies
  }

  /// Premier plan, ou compte relu (connexion, liaison) : ouvre le canal s'il y a lieu. Sans effet s'il est ouvert pour
  /// le même compte ; un autre compte le rouvre.
  func foreground() async {
    guard let transport, dependencies.isEmailAccount(), let userId = await dependencies.accountId() else {
      await background()
      return
    }
    if listener != nil, openedFor == userId { return }
    await background()
    await closing?.value
    openedFor = userId
    listener = Task { [weak self] in
      while !Task.isCancelled {
        let stream = await transport.userSignals(userId: userId)
        for await event in stream { self?.handle(event) }
        // Canal refusé, ou fermé par le serveur : il ne se rejoint plus de lui-même.
        guard !Task.isCancelled, let sleep = self?.dependencies.sleep else { return }
        Self.logger.notice("Canal temps réel fermé, nouvel essai plus tard")
        do { try await sleep(Self.retryDelay) } catch { return }
      }
    }
  }

  /// Arrière-plan, déconnexion, compte anonyme : le canal se ferme. Les signaux déjà reçus partent tout de suite.
  func background() async {
    guard let listener else { return }
    listener.cancel()
    self.listener = nil
    openedFor = nil
    if !pending.isEmpty { flush() }
    guard let transport else { return }
    let closing = Task { await transport.closeUserSignals() }
    self.closing = closing
    await closing.value
  }

  /// Événement du canal.
  func handle(_ event: RealtimeEvent) {
    switch event {
    case .subscribed:
      // (Re)connexion : une descente rattrape ce qui a pu être manqué.
      dependencies.pull()
    case .signal(let signal):
      pending.append(signal)
      guard flushTask == nil else { return }
      let sleep = dependencies.sleep
      flushTask = Task { [weak self] in
        do { try await sleep(Self.groupingDelay) } catch { return }
        self?.flush()
      }
    }
  }

  /// Applique les signaux reçus pendant la fenêtre de regroupement : une seule descente, une seule relecture.
  func flush() {
    flushTask?.cancel()
    flushTask = nil
    let signals = pending
    pending = []
    var actions: Set<SignalAction> = []
    var sharing: [UUID] = []
    for signal in signals {
      let sheetOpen = dependencies.isSharingSheetOpen(signal.listId)
      for action in SharingDecisions.signalActions(kind: signal.kind, sharingSheetOpen: sheetOpen) {
        actions.insert(action)
        if action == .reloadSharing, let listId = signal.listId, !sharing.contains(listId) { sharing.append(listId) }
      }
    }
    if actions.contains(.pull) { dependencies.pull() }
    if actions.contains(.reloadInvitations) { dependencies.reloadInvitations() }
    for listId in sharing { dependencies.reloadSharing(listId) }
  }
}
