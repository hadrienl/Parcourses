import Domain
import Foundation
import OSLog
import SwiftData

extension Notification.Name {
  /// La synchronisation a modifié des données affichées : les écrans relisent.
  static let syncDidChangeData = Notification.Name("app.parcourses.syncDidChangeData")
  /// Les données locales ont changé d'identifiants : `IdentifierRemap`, remis de façon synchrone sur le MainActor.
  nonisolated static let syncDidRekeyData = Notification.Name("app.parcourses.syncDidRekeyData")
}

/// Plafonds et délais de reprise (#9 §5.3).
nonisolated enum SyncRetryPolicy {
  /// `23503` : le parent peut encore arriver, mais pas indéfiniment.
  static let maxDependencyAttempts = 8
  /// Catégorie inconnue : le serveur peut être en retard d'une migration. Jamais abandonnée.
  static let unknownCategoryDelay: TimeInterval = 3600
  static let minimumDelay: TimeInterval = 2
  static let maximumDelay: TimeInterval = 300
  /// Erreur serveur sur une même ligne : au-delà, elle ne retient plus le reste de la file.
  static let serverFailureGrace: TimeInterval = 4 * 3600
  /// Délai avant de réessayer une ligne mise de côté. Reste `pending`.
  static let parkedRetryDelay: TimeInterval = 6 * 3600
  /// Article refusé (`42501`) parce que sa liste n'est pas encore reçue : il attend la liste, sans consommer d'essai.
  static let listWaitDelay: TimeInterval = 30
  /// Catalogue : une fois par jour (#9 §5.4).
  static let catalogInterval: TimeInterval = 86_400
  /// Descente après un envoi : l'envoi d'une coche ne doit pas relire les listes à chaque fois.
  static let pullAfterSendInterval: TimeInterval = 60
  /// Une descente en échec ne se retente qu'une fois par minute, sans gêner l'envoi.
  static let pullRetryInterval: TimeInterval = 60

  /// Entrées par appel à `resolve_products`, sa limite côté serveur.
  static let maxResolutionBatch = 100
  /// Résolution des produits en échec : l'envoi continue, la résolution attend.
  static let resolutionRetryInterval: TimeInterval = 60
  /// RPC absente du serveur (`PGRST202`) : l'app peut sortir avant la migration, qui arrivera vite.
  static let resolutionUnavailableInterval: TimeInterval = 300
  /// Autre refus définitif (requête refusée) : inutile d'insister à chaque passe.
  static let resolutionRejectedInterval: TimeInterval = 3600

  /// Délai de la résolution après une erreur.
  static func resolutionDelay(after error: any Error) -> TimeInterval {
    guard let remote = error as? RemoteError else { return resolutionRetryInterval }
    if remote == .rejected(code: RemoteError.functionNotFoundCode) { return resolutionUnavailableInterval }
    return remote.isRetryable ? resolutionRetryInterval : resolutionRejectedInterval
  }

  static func delay(attempt: Int, jitter: Double) -> TimeInterval {
    let exponent = min(max(attempt, 1) - 1, 16)
    return min(maximumDelay, minimumDelay * pow(2, Double(exponent)) * jitter)
  }
}

/// Vide la file puis descend les données. Une seule passe à la fois.
///
/// Une erreur sans réponse exploitable (réseau, 5xx, 401) arrête la passe avec un délai global et ne consomme
/// aucun essai de l'entrée : couper le réseau ne doit jamais rapprocher une coche de l'abandon.
///
/// Une ligne qui reçoit une erreur serveur retient d'abord toute la file, comme une panne. Passé
/// `serverFailureGrace`, elle est mise de côté, sans jamais passer en `failed`, et ses dépendances attendent avec elle.
///
/// Un nouveau compte déclenche `AccountRekey` avant tout envoi. Un Keychain verrouillé n'est pas une session
/// perdue : `keychainLocked` n'est qu'un délai, et ne touche à rien.
///
/// Le moteur ignore comment la session est obtenue : il ne connaît que `unauthorized` et `accountChanged`.
actor SyncEngine {
  nonisolated struct Dependencies: Sendable {
    var now: @Sendable () -> Date = { .now }
    var jitter: @Sendable () -> Double = { Double.random(in: 0.8...1.2) }
    var isOnline: @Sendable () -> Bool = { true }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
  }

  private static let logger = Logger(subsystem: "app.parcourses", category: "sync")

  private let gateway: any RemoteGateway
  /// Créé au premier usage, sur l'exécuteur de l'acteur : construit depuis le MainActor, un `@ModelActor`
  /// exécuterait son contexte sur le thread principal.
  private lazy var store = SyncStore(modelContainer: container)
  private let container: ModelContainer
  private let classify: @Sendable (String) -> PulledItemClassification
  private let dependencies: Dependencies
  private var cursors: any SyncCursors

  /// Pas de session valide : seule une passe forcée tente d'en retrouver une.
  private(set) var isWaitingForSession = false
  /// Suppression du compte en cours (#68 §5.3) : aucune passe ne démarre, aucun réveil n'est planifié. Les demandes
  /// sont retenues et partent à la reprise.
  private(set) var isSuspended: Bool
  /// Arrêté pour de bon : le moteur d'un compte supprimé, remplacé par un neuf.
  private(set) var isStopped = false
  /// Une erreur serveur a retenu la file : le prochain succès prouve la reprise et libère les lignes mises de côté.
  /// En mémoire : après un relancement pendant la panne, une ligne attend au pire la fin de son délai.
  private var isServerOutageSuspected = false
  /// Le compte a changé : réidentifier avant tout envoi.
  private var needsAccountRecovery = false
  /// La file n'a pas encore été confrontée aux données locales depuis ce lancement.
  private var needsReconciliation = true

  private var runner: Task<Void, Never>?
  private var wake: Task<Void, Never>?
  private var isRunRequested = false
  private var isPullRequested = false
  private var transientFailures = 0
  private var backoffUntil: Date?
  private var pullBackoffUntil: Date?
  private var lastPull: Date?
  /// Libellé déjà soumis à `resolve_products`, par article : sans produit, il n'est pas renvoyé avant le prochain
  /// lancement (quota du jour, catégorie refusée). Un libellé modifié repart.
  private var resolutionAttempts: [UUID: String] = [:]
  private var resolutionBackoffUntil: Date?

  init(
    gateway: any RemoteGateway, container: ModelContainer, cursors: any SyncCursors,
    classify: @escaping @Sendable (String) -> PulledItemClassification,
    dependencies: Dependencies = Dependencies(), suspended: Bool = false
  ) {
    isSuspended = suspended
    self.gateway = gateway
    self.container = container
    self.cursors = cursors
    self.classify = classify
    self.dependencies = dependencies
  }

  /// Une session valide est peut-être revenue, ou la suppression du compte est abandonnée : lève la suspension.
  /// Sans effet après `stop()`.
  func resume() {
    guard !isStopped else { return }
    isSuspended = false
    isWaitingForSession = false
    pullBackoffUntil = nil
    kick(pull: true)
  }

  /// Arrêt définitif, avant la purge d'un compte supprimé : ce moteur ne repartira plus.
  func stop() async {
    isStopped = true
    await suspend()
  }

  /// Arrête la synchronisation avant une suppression de compte et attend la fin de la passe en cours, interrompue
  /// comme à la fin du temps d'arrière-plan : la file reste intacte. Rien ne repart avant `resume()`.
  func suspend() async {
    isSuspended = true
    wake?.cancel()
    wake = nil
    guard let runner else { return }
    runner.cancel()
    await runner.value
  }

  /// Vrai si le contexte de synchronisation tourne sur le thread principal.
  func storeIsOnMainThread() async -> Bool {
    await store.isOnMainThread()
  }

  /// Demande une passe. `pull` : lancement, premier plan, retour du réseau, arrière-plan ; lève aussi le délai.
  func kick(pull: Bool = false) {
    isRunRequested = true
    if pull {
      isPullRequested = true
      backoffUntil = nil
    }
    guard runner == nil, !isSuspended else { return }
    runner = Task { await self.runLoop() }
  }

  /// Comme `kick`, et attend la fin. L'annulation (fin du temps d'arrière-plan) interrompt la passe.
  func drain(pull: Bool = false) async {
    kick(pull: pull)
    guard let runner else { return }
    await withTaskCancellationHandler {
      await runner.value
    } onCancel: {
      runner.cancel()
    }
  }

  private func runLoop() async {
    while isRunRequested, !Task.isCancelled, !isSuspended {
      isRunRequested = false
      let pull = isPullRequested
      isPullRequested = false
      await pass(pull: pull)
    }
    runner = nil
    // Suspendu : la demande attend `resume()`, sans réveil.
    if isSuspended { return }
    // Une demande arrivée pendant une annulation n'est pas perdue : la nouvelle tâche n'est pas annulée.
    if isRunRequested {
      runner = Task { await self.runLoop() }
    } else {
      isRunRequested = false
      scheduleWake()
    }
  }

  // MARK: - Passe

  private func pass(pull requested: Bool) async {
    var pull = requested
    await reconcileQueueIfNeeded()
    // Une descente demandée reste due si la passe s'arrête avant elle.
    guard dependencies.isOnline() else {
      if pull { isPullRequested = true }
      return
    }
    if isWaitingForSession {
      // Seule une passe forcée (premier plan, réseau) tente de retrouver une session.
      guard pull else { return }
      guard await restoreSession() else {
        isPullRequested = true
        return
      }
    }
    if let backoffUntil, backoffUntil > dependencies.now() {
      if pull { isPullRequested = true }
      return
    }
    switch await prepareAccount() {
    case .stopped:
      if pull { isPullRequested = true }
      return
    case .recovered: pull = true
    case .ready: break
    }
    // Curseur des pierres tombales trop vieux : les articles supprimés ailleurs pendant la longue absence partent avant
    // qu'un envoi ne les touche (README des vecteurs).
    guard await reconcileItemsBeforeSending() else {
      if pull { isPullRequested = true }
      return
    }
    // Avant l'envoi : l'article et ses coches en file partent avec leur produit.
    await resolveProducts()
    guard let sent = await sendQueue() else {
      if pull { isPullRequested = true }
      return
    }
    transientFailures = 0
    backoffUntil = nil
    let now = dependencies.now()
    let isPullDue =
      sent > 0 && lastPull.map { now.timeIntervalSince($0) >= SyncRetryPolicy.pullAfterSendInterval } ?? true
    guard pull || isPullDue else { return }
    if let pullBackoffUntil, pullBackoffUntil > now {
      isPullRequested = true
    } else {
      await pullAll(at: now)
    }
  }

  /// Au lancement, avant tout envoi : une donnée `pending` sans entrée active reçoit la sienne. Purement local,
  /// donc aussi hors ligne. Un échec local laisse l'indicateur levé : la passe suivante recommence.
  private func reconcileQueueIfNeeded() async {
    guard needsReconciliation else { return }
    guard await reconcileQueue() else { return }
    needsReconciliation = false
  }

  private func reconcileQueue() async -> Bool {
    let now = dependencies.now()
    do {
      let queued = try await MainActor.run { [container] in
        try OutboxReconciliation.run(in: container.mainContext, now: now)
      }
      if queued > 0 { Self.logger.notice("File réconciliée : \(queued, privacy: .public) entrée(s) ajoutée(s)") }
      return true
    } catch {
      Self.logger.error("Réconciliation impossible : \(String(describing: error), privacy: .private)")
      return false
    }
  }

  private func restoreSession() async -> Bool {
    do {
      try await gateway.ensureSession(captchaToken: nil)
      isWaitingForSession = false
      return true
    } catch {
      _ = stop(on: error)
      return false
    }
  }

  private enum AccountState {
    case ready
    case recovered
    case stopped
  }

  /// Les données locales correspondent-elles au compte de la session ? Le curseur couvre le Keychain vidé
  /// (restauration sur un autre iPhone), où la passerelle n'a plus de dernier compte à comparer.
  private func prepareAccount() async -> AccountState {
    do {
      if !needsAccountRecovery {
        let id = try await gateway.currentAccountId()
        if let known = cursors.accountId, known != id {
          needsAccountRecovery = true
        } else {
          cursors.accountId = id
          await noteAccountKind()
          return .ready
        }
      }
    } catch RemoteError.accountChanged {
      needsAccountRecovery = true
    } catch {
      _ = stop(on: error)
      return .stopped
    }
    return await recoverAccount()
  }

  /// Ordre important pour la reprise après un arrêt : tant que `acknowledgeAccount` n'a pas écrit, chaque requête
  /// lève `accountChanged`, rien ne part, et l'opération recommence depuis le début.
  private func recoverAccount() async -> AccountState {
    do {
      // D'abord le compte : sans session établie (Keychain verrouillé compris), on ne touche à rien.
      let id = try await gateway.sessionAccountId()
      let now = dependencies.now()
      let previous = cursors.accountId
      let previousKind = cursors.accountKind ?? .anonymous
      try await MainActor.run { [container] in
        let remap = try AccountRekey.run(
          in: container.mainContext, previousAccountId: previous, previousAccountKind: previousKind, now: now)
        NotificationCenter.default.post(
          name: .syncDidRekeyData, object: nil, userInfo: [IdentifierRemap.userInfoKey: remap])
        NotificationCenter.default.post(name: .syncDidChangeData, object: nil)
      }
      // Contexte neuf : l'ancien pourrait garder en mémoire les lignes d'avant.
      store = SyncStore(modelContainer: container)
      cursors.lists = nil
      cursors.items = nil
      // Sans curseur : la première descente du nouveau compte réconcilie ses articles en entier (vecteur `007`).
      cursors.tombstones = nil
      cursors.accountId = id
      cursors.accountKind = nil
      await noteAccountKind()
      try await gateway.acknowledgeAccount(id)
      needsAccountRecovery = false
      isWaitingForSession = false
      lastPull = nil
      pullBackoffUntil = nil
      Self.logger.notice("Données locales réidentifiées pour un nouveau compte")
      return .recovered
    } catch {
      needsAccountRecovery = true
      _ = stop(on: error, recovering: true)
      return .stopped
    }
  }

  /// Nature du compte des données, lue dans la session (sans appel au serveur). Illisible : rien ne change.
  private func noteAccountKind() async {
    do {
      cursors.accountKind = try await gateway.accountEmail() == nil ? .anonymous : .email
    } catch {
      // Keychain verrouillé : la nature déjà notée reste.
    }
  }

  /// Classe une erreur de session ou de transport. Annulation : rien à retenir, aucun délai.
  private func stop(on error: any Error, recovering: Bool = false) -> Next {
    guard !Task.isCancelled else { return .stop }
    switch error as? RemoteError {
    case .accountChanged:
      needsAccountRecovery = true
      isWaitingForSession = false
      // Pendant la reprise, une nouvelle erreur attend le délai : pas de boucle serrée.
      if recovering { registerTransientFailure() } else { isRunRequested = true }
    case .unauthorized, .accountGone: isWaitingForSession = true
    default: registerTransientFailure()
    }
    return .stop
  }

  /// `nil` si le serveur confirme la session. Une session perdue ne doit jamais produire de `failed`.
  private func confirmSession() async -> Next? {
    do {
      try await gateway.verifySession()
      return nil
    } catch {
      return stop(on: error)
    }
  }

  /// Nombre de lots envoyés, `nil` si la passe s'est arrêtée sur une erreur passagère.
  private func sendQueue() async -> Int? {
    var sent = 0
    var singleChecks: Set<UUID> = []
    do {
      while !Task.isCancelled {
        guard let work = try await store.nextWork(now: dependencies.now(), singleChecks: singleChecks) else {
          return sent
        }
        do {
          if case .untouched(let listId) = try await send(work) {
            isWaitingForSession = false
            switch try await handleUntouched(work, listId: listId) {
            case .proceed: continue
            case .stop: return nil
            }
          }
          try await store.complete(work)
          isWaitingForSession = false
          try await releaseParkedIfRecovered()
          sent += 1
        } catch {
          if Task.isCancelled { return nil }
          // Charge utile illisible : la rejouer ne changerait rien.
          let remote = error as? RemoteError ?? (error is DecodingError ? .rejected(code: "payload") : .unexpected)
          switch try await handle(remote, for: work, singleChecks: &singleChecks) {
          case .proceed: break
          case .stop: return nil
          }
        }
      }
      return nil
    } catch {
      // Écriture locale impossible : la file reste telle quelle, on réessaiera.
      Self.logger.error("Passe interrompue : \(String(describing: error), privacy: .private)")
      registerTransientFailure()
      return nil
    }
  }

  /// Donne un produit partagé aux articles saisis librement (apprentissage sans catalogue). Un échec ne retient
  /// jamais la file : la résolution attend seule, et l'envoi décide du délai global s'il échoue aussi.
  private func resolveProducts() async {
    let now = dependencies.now()
    if let resolutionBackoffUntil, resolutionBackoffUntil > now { return }
    do {
      while !Task.isCancelled {
        let candidates = try await store.productCandidates(
          excluding: resolutionAttempts, limit: SyncRetryPolicy.maxResolutionBatch)
        guard !candidates.isEmpty else { break }
        let rows = try await gateway.resolveProducts(candidates.map(\.request))
        guard rows.count == candidates.count else { throw RemoteError.unexpected }
        for candidate in candidates { resolutionAttempts[candidate.itemId] = candidate.label }
        let matches = zip(candidates, rows).compactMap { ProductMatch($0, $1) }
        guard !matches.isEmpty else { continue }
        let changed = try await MainActor.run { [container] in
          let changed = try ProductResolution.apply(matches, in: container.mainContext, at: now)
          if changed { NotificationCenter.default.post(name: .syncDidChangeData, object: nil) }
          return changed
        }
        if changed { Self.logger.debug("Produits résolus : \(matches.count, privacy: .public)") }
      }
      resolutionBackoffUntil = nil
    } catch {
      guard !Task.isCancelled else { return }
      Self.logger.notice("Résolution des produits reportée : \(String(describing: error), privacy: .private)")
      let delay = SyncRetryPolicy.resolutionDelay(after: error)
      resolutionBackoffUntil = now.addingTimeInterval(delay * dependencies.jitter())
    }
  }

  private func releaseParkedIfRecovered() async throws {
    guard isServerOutageSuspected else { return }
    isServerOutageSuspected = false
    try await store.releaseParked(now: dependencies.now())
  }

  /// Issue d'un envoi accepté par le serveur.
  private enum SendOutcome {
    case sent
    /// Mise à jour ou suppression d'un article déjà sur le serveur sans aucune ligne touchée : supprimé ailleurs, ou
    /// accès perdu (la RLS filtre sans erreur).
    case untouched(listId: UUID)
  }

  private func send(_ work: OutboxWork) async throws -> SendOutcome {
    switch work.kind {
    case .upsertList:
      try await gateway.saveList(try OutboxCoding.decode(ListUpsert.self, from: work.payloads[0]))
    case .deleteList:
      try await gateway.deleteList(id: work.entityId)
    case .upsertItem:
      return try await sendItem(work)
    case .deleteItem:
      let payload = try? OutboxCoding.decode(ItemDeletionPayload.self, from: work.payloads[0])
      if try await gateway.deleteItem(id: work.entityId) { return .sent }
      // Jamais accusé, ou entrée écrite avant 87.3 : il n'y avait peut-être rien à supprimer, ce n'est pas un refus.
      guard payload?.isOnServer == true, let listId = payload?.listId else { return .sent }
      return .untouched(listId: listId)
    case .createVisit:
      try await gateway.createVisit(try OutboxCoding.decode(VisitInsert.self, from: work.payloads[0]))
    case .insertChecks:
      let uploads = try work.payloads.compactMap { try OutboxCoding.decode(CheckPayload.self, from: $0).upload }
      guard uploads.count == work.payloads.count else { throw RemoteError.rejected(code: "check-without-target") }
      try await gateway.insertChecks(uploads)
    case .closeVisit:
      let close = try OutboxCoding.decode(VisitClosePayload.self, from: work.payloads[0])
      try await gateway.closeVisit(id: close.visitId, endedAt: close.endedAt)
    }
    return .sent
  }

  /// Insertion complète d'un article jamais arrivé, sinon les seuls champs modifiés (vecteur `001`), sans repli sur
  /// l'insertion : un article supprimé ailleurs ne doit pas revenir.
  private func sendItem(_ work: OutboxWork) async throws -> SendOutcome {
    let row = try OutboxCoding.decode(ListItemUpsert.self, from: work.payloads[0])
    guard let changed = work.changedFields else {
      // Entrée écrite avant 87.3 : on ignore ce qui a changé et si l'article est arrivé. Toute la ligne part, puis
      // l'insertion s'il n'existait pas ; le serveur ignore celle d'un article supprimé (pierre tombale).
      let fields = ListItemFields(values: row, columns: ListItemFields.all)
      if try await !gateway.updateItem(id: row.id, fields: fields) { try await gateway.insertItem(row) }
      return .sent
    }
    switch SyncDecisions.itemSaveRequest(isOnServer: work.isOnServer, changedFields: changed) {
    case .insert:
      if try await gateway.insertItem(row) { return .sent }
      // Rien d'inséré : la ligne existait déjà (réponse d'une insertion précédente perdue, article d'avant la
      // migration) ou elle est enterrée. Les champs de l'entrée partent en mise à jour, sinon une coche faite entre-temps
      // n'arriverait jamais ; 0 ligne se tranche ensuite par la pierre tombale.
      let columns = SyncDecisions.mergeChangedFields(pending: nil, new: changed)
      guard !columns.isEmpty else { return .sent }
      let touched = try await gateway.updateItem(id: row.id, fields: ListItemFields(values: row, columns: columns))
      if !touched { return .untouched(listId: row.listId) }
    case .patch(let columns):
      let touched = try await gateway.updateItem(id: row.id, fields: ListItemFields(values: row, columns: columns))
      if !touched { return .untouched(listId: row.listId) }
    case .none:
      break
    }
    return .sent
  }

  /// 0 ligne touchée : la pierre tombale de l'article lève le doute (vecteur `003`).
  private func handleUntouched(_ work: OutboxWork, listId: UUID) async throws -> Next {
    let tombstones: [TombstoneRow]
    do {
      tombstones = try await gateway.fetchTombstones(ids: [work.entityId])
    } catch {
      return stop(on: error)
    }
    let ownerId = try await store.listOwnership(listId).ownerId
    let ownedByMe = ownerId.map { $0 == cursors.accountId } ?? true
    switch SyncDecisions.zeroRowOutcome(
      tombstoned: tombstones.contains { $0.id == work.entityId }, listOwnedByMe: ownedByMe)
    {
    case .deletedElsewhere:
      // L'article et ses entrées partent, sans nouvel essai : la suppression gagne. Les autres entrées restent.
      let row = TombstoneRow(id: work.entityId, listId: listId, deletedAt: dependencies.now())
      if try await store.merge(tombstones: [row]) { await Self.postDataChange() }
      return .proceed
    case .accessLost:
      do {
        try await refreshAccess(listId: listId)
      } catch {
        return stop(on: error)
      }
      return .proceed
    }
  }

  /// Accès perdu ou rôle abaissé (#87 §6.4) : `list_sharing` relit mon rôle. Refus (`not allowed`) : la liste n'est
  /// plus accessible et quitte l'appareil. Sinon rôle et participants sont posés, les entrées de ses articles jetées
  /// et elle est rechargée entièrement ; en lecture seule, toutes ses entrées partent.
  func refreshAccess(listId: UUID) async throws {
    let sharing: ListSharing
    do {
      sharing = try await gateway.listSharing(listId: listId)
    } catch RemoteError.forbidden {
      // Une ligne de cette liste était sur le serveur : elle en a disparu, même si l'appareil ne l'a jamais descendue.
      let removed = try await store.listsSharedWithMe()[listId]
      let name = try await store.listName(listId)
      try await store.forget(listId: listId)
      await Self.postDataChange()
      if let name {
        await Self.postAccessChanges([
          removed ?? SharingAccessChange(listId: listId, listName: name, ownerName: nil, kind: .removed)
        ])
      }
      return
    }
    let dropped = try await store.pendingItemWrites(listId: listId)
    let previous = try await store.applySharing(sharing)
    let rows = try await gateway.fetchItems(listId: listId)
    // Liste à soi : les articles jamais envoyés et leurs entrées restent, rien ne les a refusés.
    _ = try await store.replaceItems(
      listId: listId, rows: rows, keepingUnsent: sharing.role == .owner, classify: classify)
    await Self.postDataChange()
    guard let previous, var kind = ListMemberships.change(from: previous, to: sharing.role) else { return }
    if case .downgraded = kind { kind = .downgraded(droppedChanges: dropped) }
    let name = try await store.listName(listId) ?? ""
    await Self.postAccessChanges([
      SharingAccessChange(listId: listId, listName: name, ownerName: sharing.owner.displayName, kind: kind)
    ])
  }

  private static func postAccessChanges(_ changes: [SharingAccessChange]) async {
    guard !changes.isEmpty else { return }
    await MainActor.run {
      for change in changes { NotificationCenter.default.post(name: .sharingAccessDidChange, object: change) }
    }
  }

  private static func postDataChange() async {
    await MainActor.run { NotificationCenter.default.post(name: .syncDidChangeData, object: nil) }
  }

  private enum Next {
    case proceed
    case stop
  }

  private func handle(
    _ error: RemoteError, for work: OutboxWork, singleChecks: inout Set<UUID>
  ) async throws -> Next {
    switch error {
    case .accountChanged, .unauthorized, .network, .keychainLocked, .accountGone, .notSent:
      return stop(on: error)

    case .unexpected:
      return try await handleServerFailure(error, work, singleChecks: &singleChecks)

    case .server:
      guard error.isCappedClientFailure else {
        return try await handleServerFailure(error, work, singleChecks: &singleChecks)
      }
      return try await retryCapped(
        error, work, limit: SyncRetryPolicy.maxDependencyAttempts, singleChecks: &singleChecks)

    case .dependencyMissing:
      return try await retryCapped(
        error, work, limit: SyncRetryPolicy.maxDependencyAttempts, singleChecks: &singleChecks)

    case .unknownCategory:
      if split(work, into: &singleChecks) { return .proceed }
      let delay = SyncRetryPolicy.unknownCategoryDelay * dependencies.jitter()
      try await store.postpone(
        work, attempts: work.attempts + 1, until: dependencies.now().addingTimeInterval(delay),
        reason: String(describing: error))
      return .proceed

    case .forbidden:
      return try await handleForbidden(work)

    case .constraint, .rejected:
      if error == .constraint(code: "23514"), work.kind.carriesDeviceTime {
        switch try await correctClock(work) {
        case .corrected: return .proceed
        case .stopped: return .stop
        case .noServerTime:
          // Rien ne prouve que la ligne soit fautive : de côté, sans essai consommé, jamais `failed`.
          try await store.postpone(
            work, attempts: work.attempts,
            until: dependencies.now().addingTimeInterval(SyncRetryPolicy.parkedRetryDelay * dependencies.jitter()),
            reason: "\(error), heure du serveur inconnue")
          return .proceed
        case .notAhead: break
        }
      }
      if split(work, into: &singleChecks) { return .proceed }
      try await failDefinitively(work, reason: String(describing: error))
      return .proceed
    }
  }

  /// La panne retient la file jusqu'à la fin du délai : une panne générale ne doit rien mettre de côté trop tôt.
  /// Le départ de la panne n'est effacé que par un succès : une ligne déjà mise de côté y retourne dès son échec.
  private func handleServerFailure(
    _ error: RemoteError, _ work: OutboxWork, singleChecks: inout Set<UUID>
  ) async throws -> Next {
    let now = dependencies.now()
    let since = try await store.markServerFailure(work, at: now, reason: String(describing: error))
    guard now.timeIntervalSince(since) >= SyncRetryPolicy.serverFailureGrace else {
      isServerOutageSuspected = true
      return stop(on: error)
    }
    if split(work, into: &singleChecks) { return .proceed }
    let delay = SyncRetryPolicy.parkedRetryDelay * dependencies.jitter()
    try await store.postpone(
      work, attempts: work.attempts, until: now.addingTimeInterval(delay), reason: String(describing: error))
    Self.logger.notice("Entrée mise de côté (\(work.kind.rawValue, privacy: .public))")
    return .proceed
  }

  private enum ClockOutcome {
    case corrected
    case notAhead
    case noServerTime
    case stopped
  }

  /// `23514` : seul un horodatage trop loin dans le futur se corrige. Tout le lot d'un coup, sans essai consommé :
  /// la date renvoyée n'est jamais après l'heure du serveur, le prochain refus éventuel a donc une autre cause.
  private func correctClock(_ work: OutboxWork) async throws -> ClockOutcome {
    let serverNow: Date?
    do {
      serverNow = try await gateway.serverDate()
    } catch {
      _ = stop(on: error)
      return .stopped
    }
    guard let serverNow else { return .noServerTime }
    let clock = ServerClock(serverNow: serverNow, deviceNow: dependencies.now())
    return try await store.correctClock(work, clock: clock) ? .corrected : .notAhead
  }

  private func retryCapped(
    _ error: RemoteError, _ work: OutboxWork, limit: Int, singleChecks: inout Set<UUID>
  ) async throws -> Next {
    if split(work, into: &singleChecks) { return .proceed }
    return try await capAttempts(error, work, limit: limit)
  }

  /// Compte un refus sur tout le lot : abandon au plafond, délai croissant sinon.
  private func capAttempts(_ error: RemoteError, _ work: OutboxWork, limit: Int) async throws -> Next {
    let attempts = work.attempts + 1
    guard attempts < limit else {
      if let stopped = await confirmSession() { return stopped }
      try await failDefinitively(work, reason: "\(error), plafond atteint")
      return .proceed
    }
    let delay = SyncRetryPolicy.delay(attempt: attempts, jitter: dependencies.jitter())
    try await store.postpone(
      work, attempts: attempts, until: dependencies.now().addingTimeInterval(delay), reason: String(describing: error))
    return .proceed
  }

  /// Un lot refusé pour une raison propre à une ligne repart ligne à ligne, sans consommer d'essai.
  private func split(_ work: OutboxWork, into singleChecks: inout Set<UUID>) -> Bool {
    guard work.kind == .insertChecks, work.entryIds.count > 1,
      let first = try? OutboxCoding.decode(CheckPayload.self, from: work.payloads[0])
    else { return false }
    singleChecks.insert(first.visitId)
    return true
  }

  private func failDefinitively(_ work: OutboxWork, reason: String) async throws {
    if work.kind == .createVisit {
      try await store.failVisit(work.entityId, reason: reason)
    } else {
      try await store.fail(work, reason: reason)
    }
  }

  /// `42501` ne signifie pas la même chose selon l'entrée.
  private func handleForbidden(_ work: OutboxWork) async throws -> Next {
    switch work.kind {
    case .createVisit:
      if try await waitForList(work) { return .proceed }
      // Liste supprimée entre-temps : la visite reste utile au graphe, on la renvoie sans liste.
      let row = try OutboxCoding.decode(VisitInsert.self, from: work.payloads[0])
      guard row.listId == nil else {
        try await store.removeListFromCreation(work)
        return .proceed
      }
      if let stopped = await confirmSession() { return stopped }
      try await store.failVisit(work.entityId, reason: "42501 sur une visite sans liste")
      return .proceed

    case .insertChecks:
      return try await handleForbiddenChecks(work)

    case .upsertItem:
      return try await handleRefusedItem(work)

    default:
      return try await failForbidden(work)
    }
  }

  /// `42501` sur un article (vecteur `004`) : liste pas encore partie, liste d'autrui (rôle abaissé, retrait) ou liste à
  /// soi.
  private func handleRefusedItem(_ work: OutboxWork) async throws -> Next {
    let row = try OutboxCoding.decode(ListItemUpsert.self, from: work.payloads[0])
    let ownership = try await store.listOwnership(row.listId)
    let ownedByMe = ownership.ownerId.map { $0 == cursors.accountId } ?? true
    switch SyncDecisions.insertRefusedOutcome(listSynced: ownership.synced, listOwnedByMe: ownedByMe) {
    case .waitForList:
      if try await waitForList(work) { return .proceed }
      return try await failForbidden(work)
    case .refreshAccess:
      do {
        try await refreshAccess(listId: row.listId)
      } catch {
        return stop(on: error)
      }
      return .proceed
    case .reconcile:
      // Liste supprimée ailleurs, sans doute : la descente qui suit la retire (`accessible_list_ids`).
      isRunRequested = true
      isPullRequested = true
      return try await failForbidden(work)
    }
  }

  private func failForbidden(_ work: OutboxWork) async throws -> Next {
    if let stopped = await confirmSession() { return stopped }
    try await store.fail(work, reason: OutboxReconciliation.forbiddenReason)
    return .proceed
  }

  /// `42501` sur un article dont la liste n'est pas encore arrivée au serveur : la RLS ne voit pas la liste, ce
  /// n'est pas un refus de l'article (ni de la visite). Il attend la liste, sans essai consommé ; la liste est remise en file si
  /// elle n'y est plus. Faux si la liste est reçue (ou abandonnée) : le refus est alors bien celui de l'article.
  private func waitForList(_ work: OutboxWork) async throws -> Bool {
    guard let listId = try await store.unsentListId(of: work) else { return false }
    guard await reconcileQueue() else { return false }
    try await store.postpone(
      work, attempts: work.attempts,
      until: dependencies.now().addingTimeInterval(SyncRetryPolicy.listWaitDelay * dependencies.jitter()),
      reason: "\(OutboxReconciliation.forbiddenReason), liste \(listId) pas encore reçue")
    return true
  }

  /// Visite close et à nous : coche « reçue » (contrat hors ligne). Visite invisible : elle vient d'un autre
  /// compte et les coches ne sont arrivées nulle part : elles restent en local en `failed`, jamais marquées
  /// reçues. Ne pas mettre toute la file en pause : une seule visite la bloquerait pour toujours.
  private func handleForbiddenChecks(_ work: OutboxWork) async throws -> Next {
    let first = try OutboxCoding.decode(CheckPayload.self, from: work.payloads[0])
    let access: VisitAccess
    do {
      access = try await gateway.visitAccess(id: first.visitId)
    } catch {
      return stop(on: error)
    }
    switch access {
    case .closed:
      Self.logger.notice("Coche tardive considérée comme reçue : visite déjà close")
      try await store.complete(work)
    case .notVisible:
      if let stopped = await confirmSession() { return stopped }
      try await store.failVisit(first.visitId, reason: "visite invisible pour ce compte")
    case .open:
      // Inexplicable d'après la RLS : ni perdue tout de suite, ni rejouée sans fin. Le refus porte sur la
      // visite, pas sur une ligne : découper le lot n'y changerait rien.
      return try await capAttempts(.forbidden, work, limit: SyncRetryPolicy.maxDependencyAttempts)
    }
    return .proceed
  }

  private func registerTransientFailure() {
    transientFailures += 1
    let delay = SyncRetryPolicy.delay(attempt: transientFailures, jitter: dependencies.jitter())
    backoffUntil = dependencies.now().addingTimeInterval(delay)
  }

  // MARK: - Descente

  private func pullAll(at now: Date) async {
    do {
      // Listes accessibles d'abord (vecteur `005`) : une liste supprimée ailleurs, ou dont l'accès a été retiré, quitte
      // l'appareil ; une liste nouvellement accessible est descendue entièrement, ses articles étant plus anciens que
      // le curseur.
      let accessible = try await gateway.accessibleListIds()
      let sharedWithMe = try await store.listsSharedWithMe()
      let reconciliation = try await store.reconcile(listIds: accessible)
      // Annoncé tout de suite : une erreur plus loin dans la descente ne doit pas faire oublier le retrait.
      await Self.postAccessChanges(reconciliation.decision.remove.compactMap { sharedWithMe[$0] })
      var accessChanges: [SharingAccessChange] = []
      let fetchFully = reconciliation.decision.fetchFully
      let lists = try await gateway.fetchLists(updatedAfter: fetchFully.isEmpty ? cursors.lists : nil)
      let items = try await gateway.fetchItems(updatedAfter: cursors.items)
      let listsMerge = try await store.merge(lists: lists)
      let itemsMerge = try await store.merge(items: items, classify: classify)
      var dataChanged = reconciliation.changed || listsMerge.changed || itemsMerge.changed
      for listId in fetchFully {
        let rows = try await gateway.fetchItems(listId: listId)
        dataChanged = try await store.merge(items: rows, classify: classify).changed || dataChanged
      }
      // Rôles et participants (#87, lot 87.4) : deux lectures, `profiles` seulement si une liste est partagée.
      if let me = cursors.accountId {
        let members = try await gateway.fetchListMembers()
        let profiles = members.isEmpty ? [] : try await gateway.fetchProfiles()
        let memberships = try await store.applyMemberships(members: members, profiles: profiles, me: me)
        for change in memberships.changes {
          guard case .downgraded = change.kind else {
            accessChanges.append(change)
            continue
          }
          // Passé lecteur : les écritures en attente de cette liste ne passeront plus, elle est rechargée.
          let dropped = try await store.pendingItemWrites(listId: change.listId)
          let rows = try await gateway.fetchItems(listId: change.listId)
          _ = try await store.replaceItems(listId: change.listId, rows: rows, keepingUnsent: false, classify: classify)
          accessChanges.append(
            SharingAccessChange(
              listId: change.listId, listName: change.listName, ownerName: change.ownerName,
              kind: .downgraded(droppedChanges: dropped)))
        }
        dataChanged = dataChanged || memberships.changed
      }
      cursors.lists = Self.later(cursors.lists, listsMerge.cursor)
      cursors.items = Self.later(cursors.items, itemsMerge.cursor)
      dataChanged = try await pullTombstones(now: now) || dataChanged
      var catalogChanged = false
      if cursors.catalog.map({ now.timeIntervalSince($0) >= SyncRetryPolicy.catalogInterval }) ?? true {
        let categories = try await gateway.fetchCategories()
        try await store.applyCategories(categories)
        // Catégories reçues : le catalogue est lisible, et une liste de produits vide veut dire « aucun produit publié »
        // (#69). Elle vide alors le cache, noms d'autres comptes téléchargés avant compris.
        catalogChanged = try await store.replaceProducts(
          try await gateway.fetchProducts(), catalogReadable: !categories.isEmpty)
        cursors.catalog = now
      }
      lastPull = now
      pullBackoffUntil = nil
      try await releaseParkedIfRecovered()
      isWaitingForSession = false
      // Catalogue changé : l'écran Liste ouvert reconstruit ses suggestions (un nom retiré n'y reste pas).
      if dataChanged || catalogChanged { await Self.postDataChange() }
      await Self.postAccessChanges(accessChanges)
    } catch {
      isPullRequested = true
      guard !Task.isCancelled else { return }
      Self.logger.notice("Descente reportée : \(String(describing: error), privacy: .private)")
      switch error as? RemoteError {
      case .accountChanged, .unauthorized, .accountGone:
        _ = stop(on: error)
      default:
        // N'arrête pas l'envoi : seul un nouvel essai de descente attend.
        pullBackoffUntil = now.addingTimeInterval(SyncRetryPolicy.pullRetryInterval)
      }
    }
  }

  /// Suppressions faites ailleurs (vecteurs `006` et `007`). Vrai si un article affiché a disparu.
  private func pullTombstones(now: Date) async throws -> Bool {
    switch SyncDecisions.tombstonePullMode(cursor: cursors.tombstones, now: now) {
    case .incremental:
      let rows = try await gateway.fetchTombstones(after: cursors.tombstones)
      let changed = try await store.merge(tombstones: rows)
      cursors.tombstones = Self.later(cursors.tombstones, rows.map(\.deletedAt).max())
      return changed
    case .fullReconcile:
      return try await reconcileItemsFully()
    }
  }

  /// Réconciliation complète des articles (vecteur `007`). Heure du serveur d'abord : une suppression faite pendant la
  /// réconciliation sera relue la fois suivante. Sans en-tête lisible, le curseur reste vide et elle recommencera.
  private func reconcileItemsFully() async throws -> Bool {
    let serverNow = try await gateway.serverDate()
    var changed = false
    for listId in try await store.reconcilableListIds() {
      let ids = try await gateway.fetchItemIds(listId: listId)
      changed = try await store.reconcileItems(listId: listId, serverIds: Set(ids)) || changed
    }
    cursors.tombstones = serverNow
    return changed
  }

  /// `fullReconcile` dû : la réconciliation complète passe avant l'envoi de la file. Faux si la passe doit s'arrêter
  /// (session perdue ou compte changé) ; une autre erreur reporte seulement la réconciliation, comme une descente.
  private func reconcileItemsBeforeSending() async -> Bool {
    let now = dependencies.now()
    guard SyncDecisions.tombstonePullMode(cursor: cursors.tombstones, now: now) == .fullReconcile else { return true }
    if let pullBackoffUntil, pullBackoffUntil > now { return true }
    do {
      // Aucune liste encore arrivée au serveur : rien à confronter, la descente posera le curseur.
      guard try await !store.reconcilableListIds().isEmpty else { return true }
      if try await reconcileItemsFully() { await Self.postDataChange() }
      return true
    } catch {
      guard !Task.isCancelled else { return false }
      switch error as? RemoteError {
      case .accountChanged, .unauthorized, .accountGone, .keychainLocked:
        _ = stop(on: error)
        return false
      default:
        Self.logger.notice("Réconciliation des articles reportée : \(String(describing: error), privacy: .private)")
        pullBackoffUntil = now.addingTimeInterval(SyncRetryPolicy.pullRetryInterval)
        return true
      }
    }
  }

  private static func later(_ first: Date?, _ second: Date?) -> Date? {
    [first, second].compactMap(\.self).max()
  }

  // MARK: - Réveil

  private func scheduleWake() {
    wake?.cancel()
    wake = nil
    guard dependencies.isOnline(), !isWaitingForSession else { return }
    let store = store
    let sleep = dependencies.sleep
    let now = dependencies.now
    let backoff = backoffUntil
    let pullDate = isPullRequested ? (pullBackoffUntil ?? now()) : nil
    wake = Task { [weak self] in
      // Une entrée déjà échue et libre compte : la passe a pu s'arrêter avant elle.
      let date = now()
      let isWorkable = (try? await store.nextWork(now: date)) != nil
      let next = isWorkable ? date : (try? await store.nextDueDate(after: date)) ?? nil
      var target = [next, pullDate].compactMap(\.self).min()
      if let backoff { target = max(target ?? backoff, backoff) }
      guard let target else { return }
      do { try await sleep(max(1, target.timeIntervalSince(now()))) } catch { return }
      await self?.kick()
    }
  }
}

/// Construit le classifieur de la descente à partir de `Domain`.
nonisolated enum PulledItemClassifier {
  static func make() throws -> @Sendable (String) -> PulledItemClassification {
    let classifier = try CategoryClassifier()
    return { label in
      let result = classifier.classify(label)
      return PulledItemClassification(normalizedName: result.normalized, categoryId: result.categoryId)
    }
  }
}
