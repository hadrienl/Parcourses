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
    /// Écho probable de ma propre écriture (`RecentItemWrites`) : temps restant de sa fenêtre, `nil` sinon.
    var echoDelay: (RealtimeSignal) -> TimeInterval? = { _ in nil }
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
  /// Descente reportée à la fin de la fenêtre d'un écho : un vrai signal d'un autre membre a pu y arriver.
  private var deferredPull: Task<Void, Never>?
  /// Fermeture en cours : une ouverture attend qu'elle soit finie.
  private var closing: Task<Void, Never>?

  /// L'app est au premier plan : posé sans attendre par la scène (`enteredForeground`, `enteredBackground`) et relu
  /// après chaque `await` d'une ouverture, pour qu'un canal ne s'ouvre jamais en arrière-plan.
  private(set) var isInForeground = true
  /// Ouverture en cours : une plus récente (ou une fermeture) l'emporte, la précédente s'arrête au prochain `await`.
  private var generation = 0

  /// Canal ouvert (ou en cours d'ouverture) pour ce compte.
  var isOpen: Bool { listener != nil }

  init(transport: (any RealtimeTransport)?, dependencies: Dependencies = Dependencies()) {
    self.transport = transport
    self.dependencies = dependencies
  }

  /// Premier plan, ou compte relu (connexion, liaison) : ouvre le canal s'il y a lieu. Sans effet s'il est ouvert pour
  /// le même compte ; un autre compte le rouvre.
  func foreground() async {
    generation += 1
    let current = generation
    guard isInForeground else { return }
    guard let transport, dependencies.isEmailAccount(), let userId = await dependencies.accountId() else {
      if isWanted(current) { await close() }
      return
    }
    guard isWanted(current) else { return }
    if listener != nil, openedFor == userId { return }
    await close()
    await closing?.value
    guard isWanted(current) else { return }
    // Jamais deux écoutes : celle d'avant est annulée avant d'être remplacée.
    listener?.cancel()
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

  /// Encore au premier plan, et aucune ouverture ni fermeture plus récente que `current` ?
  private func isWanted(_ current: Int) -> Bool {
    isInForeground && generation == current
  }

  /// Scène active : les ouvertures sont de nouveau permises. Appelé sans attendre, avant `foreground()`.
  func enteredForeground() {
    isInForeground = true
  }

  /// Scène en arrière-plan : toute ouverture en cours s'arrête à son prochain `await`. Appelé sans attendre.
  func enteredBackground() {
    isInForeground = false
    generation += 1
  }

  /// Arrière-plan : le canal se ferme, et aucune ouverture en cours ne le rouvre.
  func background() async {
    enteredBackground()
    await close()
  }

  /// Déconnexion, compte anonyme, changement de compte : le canal se ferme. Les signaux déjà reçus partent tout de
  /// suite.
  private func close() async {
    guard let listener else { return }
    listener.cancel()
    self.listener = nil
    openedFor = nil
    if !pending.isEmpty { flush() }
    // Descente reportée encore due : elle part avant la fermeture, comme les signaux en attente.
    if deferredPull != nil { pullNow() }
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
      pullNow()
    case .signal(let signal):
      if let delay = dependencies.echoDelay(signal) {
        deferPull(by: delay)
        return
      }
      pending.append(signal)
      guard flushTask == nil else { return }
      let sleep = dependencies.sleep
      flushTask = Task { [weak self] in
        do { try await sleep(Self.groupingDelay) } catch { return }
        self?.flush()
      }
    }
  }

  /// Écho probable : pas de descente tout de suite, une seule à la fin de la fenêtre. Les échos suivants ne la
  /// repoussent pas : un signal d'un autre membre caché dans la fenêtre n'attend jamais plus de 2 s.
  private func deferPull(by delay: TimeInterval) {
    guard deferredPull == nil else { return }
    let sleep = dependencies.sleep
    deferredPull = Task { [weak self] in
      do { try await sleep(.milliseconds(Int((delay * 1000).rounded(.up)))) } catch { return }
      self?.deferredPull = nil
      self?.dependencies.pull()
    }
  }

  /// Une descente part : celle qui était reportée n'a plus lieu d'être.
  private func pullNow() {
    deferredPull?.cancel()
    deferredPull = nil
    dependencies.pull()
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
    if actions.contains(.pull) { pullNow() }
    if actions.contains(.reloadInvitations) { dependencies.reloadInvitations() }
    for listId in sharing { dependencies.reloadSharing(listId) }
  }
}
