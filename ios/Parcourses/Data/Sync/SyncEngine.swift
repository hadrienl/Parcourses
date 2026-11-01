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
  /// Catalogue : une fois par jour (#9 §5.4).
  static let catalogInterval: TimeInterval = 86_400
  /// Descente après un envoi : l'envoi d'une coche ne doit pas relire les listes à chaque fois.
  static let pullAfterSendInterval: TimeInterval = 60
  /// Une descente en échec ne se retente qu'une fois par minute, sans gêner l'envoi.
  static let pullRetryInterval: TimeInterval = 60

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
  /// Le compte a changé : réidentifier avant tout envoi.
  private var needsAccountRecovery = false

  private var runner: Task<Void, Never>?
  private var wake: Task<Void, Never>?
  private var isRunRequested = false
  private var isPullRequested = false
  private var transientFailures = 0
  private var backoffUntil: Date?
  private var pullBackoffUntil: Date?
  private var lastPull: Date?

  init(
    gateway: any RemoteGateway, container: ModelContainer, cursors: any SyncCursors,
    classify: @escaping @Sendable (String) -> PulledItemClassification,
    dependencies: Dependencies = Dependencies()
  ) {
    self.gateway = gateway
    self.container = container
    self.cursors = cursors
    self.classify = classify
    self.dependencies = dependencies
  }

  /// Une session valide est peut-être revenue.
  func resume() {
    isWaitingForSession = false
    pullBackoffUntil = nil
    kick(pull: true)
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
    guard runner == nil else { return }
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
    while isRunRequested, !Task.isCancelled {
      isRunRequested = false
      let pull = isPullRequested
      isPullRequested = false
      await pass(pull: pull)
    }
    runner = nil
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
      try await MainActor.run { [container] in
        let remap = try AccountRekey.run(in: container.mainContext, now: now)
        NotificationCenter.default.post(
          name: .syncDidRekeyData, object: nil, userInfo: [IdentifierRemap.userInfoKey: remap])
        NotificationCenter.default.post(name: .syncDidChangeData, object: nil)
      }
      // Contexte neuf : l'ancien pourrait garder en mémoire les lignes d'avant.
      store = SyncStore(modelContainer: container)
      cursors.lists = nil
      cursors.items = nil
      cursors.accountId = id
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

  /// Classe une erreur de session ou de transport. Annulation : rien à retenir, aucun délai.
  private func stop(on error: any Error, recovering: Bool = false) -> Next {
    guard !Task.isCancelled else { return .stop }
    switch error as? RemoteError {
    case .accountChanged:
      needsAccountRecovery = true
      isWaitingForSession = false
      // Pendant la reprise, une nouvelle erreur attend le délai : pas de boucle serrée.
      if recovering { registerTransientFailure() } else { isRunRequested = true }
    case .unauthorized: isWaitingForSession = true
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
          try await send(work)
          try await store.complete(work)
          isWaitingForSession = false
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

  private func send(_ work: OutboxWork) async throws {
    switch work.kind {
    case .upsertList:
      try await gateway.saveList(try OutboxCoding.decode(ListUpsert.self, from: work.payloads[0]))
    case .deleteList:
      try await gateway.deleteList(id: work.entityId)
    case .upsertItem:
      try await gateway.saveItem(try OutboxCoding.decode(ListItemUpsert.self, from: work.payloads[0]))
    case .deleteItem:
      try await gateway.deleteItem(id: work.entityId)
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
  }

  private enum Next {
    case proceed
    case stop
  }

  private func handle(
    _ error: RemoteError, for work: OutboxWork, singleChecks: inout Set<UUID>
  ) async throws -> Next {
    switch error {
    case .accountChanged, .unauthorized, .network, .keychainLocked:
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
          return try await capAttempts(error, work, limit: SyncRetryPolicy.maxDependencyAttempts)
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
    guard now.timeIntervalSince(since) >= SyncRetryPolicy.serverFailureGrace else { return stop(on: error) }
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

    default:
      if let stopped = await confirmSession() { return stopped }
      try await store.fail(work, reason: "42501")
      return .proceed
    }
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
      let lists = try await gateway.fetchLists(updatedAfter: cursors.lists)
      let items = try await gateway.fetchItems(updatedAfter: cursors.items)
      let listsMerge = try await store.merge(lists: lists)
      let itemsMerge = try await store.merge(items: items, classify: classify)
      cursors.lists = Self.later(cursors.lists, listsMerge.cursor)
      cursors.items = Self.later(cursors.items, itemsMerge.cursor)
      if cursors.catalog.map({ now.timeIntervalSince($0) >= SyncRetryPolicy.catalogInterval }) ?? true {
        try await store.applyCategories(try await gateway.fetchCategories())
        try await store.replaceProducts(try await gateway.fetchProducts())
        cursors.catalog = now
      }
      lastPull = now
      pullBackoffUntil = nil
      isWaitingForSession = false
      if listsMerge.changed || itemsMerge.changed {
        await MainActor.run { NotificationCenter.default.post(name: .syncDidChangeData, object: nil) }
      }
    } catch {
      isPullRequested = true
      guard !Task.isCancelled else { return }
      Self.logger.notice("Descente reportée : \(String(describing: error), privacy: .private)")
      switch error as? RemoteError {
      case .accountChanged, .unauthorized:
        _ = stop(on: error)
      default:
        // N'arrête pas l'envoi : seul un nouvel essai de descente attend.
        pullBackoffUntil = now.addingTimeInterval(SyncRetryPolicy.pullRetryInterval)
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
