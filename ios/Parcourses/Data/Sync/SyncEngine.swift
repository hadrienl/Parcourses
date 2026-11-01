import Domain
import Foundation
import OSLog
import SwiftData

extension Notification.Name {
  /// La synchronisation a modifié des données affichées : les écrans relisent.
  static let syncDidChangeData = Notification.Name("app.parcourses.syncDidChangeData")
}

/// Pourquoi la file ne part plus. Rien n'est envoyé, rien n'est supprimé.
nonisolated enum SyncPause: Sendable, Equatable {
  /// Pas de session valide : l'écran de connexion prend la main. Reprise dès qu'une session revient.
  case sessionRequired
  /// La session appartient à un autre compte. Seul `resume()` lève cette pause, une fois la reprise décidée.
  case accountChanged
}

/// Plafonds et délais de reprise (#9 §5.3).
nonisolated enum SyncRetryPolicy {
  /// `23503` : le parent peut encore arriver, mais pas indéfiniment.
  static let maxDependencyAttempts = 8
  /// Catégorie inconnue : le serveur peut être en retard d'une migration. Environ 4 h d'essais effectifs.
  static let maxUnknownCategoryAttempts = 48
  static let minimumDelay: TimeInterval = 2
  static let maximumDelay: TimeInterval = 300
  /// Catalogue : une fois par jour (#9 §5.4).
  static let catalogInterval: TimeInterval = 86_400
  /// Descente après un envoi : l'envoi d'une coche ne doit pas relire les listes à chaque fois.
  static let pullAfterSendInterval: TimeInterval = 60

  static func delay(attempt: Int, jitter: Double) -> TimeInterval {
    let exponent = min(max(attempt, 1) - 1, 16)
    return min(maximumDelay, minimumDelay * pow(2, Double(exponent))) * jitter
  }
}

/// Vide la file puis descend les données. Une seule passe à la fois.
///
/// Une erreur sans réponse exploitable (réseau, 5xx, 401) arrête la passe avec un délai global et ne consomme
/// aucun essai de l'entrée : couper le réseau ne doit jamais rapprocher une coche de l'abandon.
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
  private let store: SyncStore
  private let container: ModelContainer
  private let classify: @Sendable (String) -> PulledItemClassification
  private let dependencies: Dependencies
  private var cursors: any SyncCursors

  /// État courant de la pause, `nil` si la file circule.
  private(set) var pause: SyncPause?
  /// Changements de `pause`, pour l'écran de connexion. Un seul auditeur.
  nonisolated let pauseUpdates: AsyncStream<SyncPause?>
  private let pauseContinuation: AsyncStream<SyncPause?>.Continuation

  private var runner: Task<Void, Never>?
  private var wake: Task<Void, Never>?
  private var isRunRequested = false
  private var isPullRequested = false
  private var transientFailures = 0
  private var backoffUntil: Date?
  private var lastPull: Date?

  init(
    gateway: any RemoteGateway, container: ModelContainer, cursors: any SyncCursors,
    classify: @escaping @Sendable (String) -> PulledItemClassification,
    dependencies: Dependencies = Dependencies()
  ) {
    self.gateway = gateway
    self.container = container
    self.store = SyncStore(modelContainer: container)
    self.cursors = cursors
    self.classify = classify
    self.dependencies = dependencies
    (pauseUpdates, pauseContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// Une session valide est peut-être revenue, ou la reprise après changement de compte est décidée.
  func resume() {
    setPause(nil)
    kick(pull: true)
  }

  private func setPause(_ value: SyncPause?) {
    guard pause != value else { return }
    pause = value
    pauseContinuation.yield(value)
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
    isRunRequested = false
    runner = nil
    scheduleWake()
  }

  // MARK: - Passe

  private func pass(pull: Bool) async {
    guard dependencies.isOnline() else { return }
    // Session requise : seule une passe forcée (premier plan, réseau) vérifie si elle est revenue.
    if pause == .accountChanged || (pause == .sessionRequired && !pull) { return }
    if let backoffUntil, backoffUntil > dependencies.now() { return }
    guard let sent = await sendQueue() else { return }
    let now = dependencies.now()
    let isPullDue =
      sent > 0 && lastPull.map { now.timeIntervalSince($0) >= SyncRetryPolicy.pullAfterSendInterval } ?? true
    if pull || isPullDue {
      await pullAll(at: now)
    } else {
      transientFailures = 0
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
          setPause(nil)
          sent += 1
        } catch {
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
    case .accountChanged:
      setPause(.accountChanged)
      return .stop

    case .unauthorized:
      setPause(.sessionRequired)
      return .stop

    case .network, .server, .unexpected:
      registerTransientFailure()
      return .stop

    case .dependencyMissing:
      return try await retryCapped(
        error, work, limit: SyncRetryPolicy.maxDependencyAttempts, singleChecks: &singleChecks)

    case .unknownCategory:
      return try await retryCapped(
        error, work, limit: SyncRetryPolicy.maxUnknownCategoryAttempts, singleChecks: &singleChecks)

    case .forbidden:
      return try await handleForbidden(work)

    case .constraint, .rejected:
      if split(work, into: &singleChecks) { return .proceed }
      try await failDefinitively(work, reason: String(describing: error))
      return .proceed
    }
  }

  private func retryCapped(
    _ error: RemoteError, _ work: OutboxWork, limit: Int, singleChecks: inout Set<UUID>
  ) async throws -> Next {
    if split(work, into: &singleChecks) { return .proceed }
    let attempts = work.attempts + 1
    guard attempts < limit else {
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
      try await store.failVisit(work.entityId, reason: "42501 sur une visite sans liste")
      return .proceed

    case .insertChecks:
      return try await handleForbiddenChecks(work)

    default:
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
    } catch RemoteError.accountChanged {
      setPause(.accountChanged)
      return .stop
    } catch RemoteError.unauthorized {
      setPause(.sessionRequired)
      return .stop
    } catch {
      registerTransientFailure()
      return .stop
    }
    switch access {
    case .closed:
      Self.logger.notice("Coche tardive considérée comme reçue : visite déjà close")
      try await store.complete(work)
    case .notVisible:
      try await store.failVisit(first.visitId, reason: "visite invisible pour ce compte")
    case .open:
      // Inexplicable d'après la RLS : ni perdue tout de suite, ni rejouée sans fin.
      var ignored: Set<UUID> = []
      return try await retryCapped(
        .forbidden, work, limit: SyncRetryPolicy.maxDependencyAttempts, singleChecks: &ignored)
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
      let listsChanged = try await store.merge(lists: lists)
      let itemsChanged = try await store.merge(items: items, classify: classify)
      cursors.lists = lists.map(\.updatedAt).max() ?? cursors.lists
      cursors.items = items.map(\.updatedAt).max() ?? cursors.items
      if cursors.catalog.map({ now.timeIntervalSince($0) >= SyncRetryPolicy.catalogInterval }) ?? true {
        try await store.applyCategories(try await gateway.fetchCategories())
        try await store.replaceProducts(try await gateway.fetchProducts())
        cursors.catalog = now
      }
      lastPull = now
      setPause(nil)
      transientFailures = 0
      backoffUntil = nil
      if listsChanged || itemsChanged {
        await MainActor.run { NotificationCenter.default.post(name: .syncDidChangeData, object: nil) }
      }
    } catch RemoteError.accountChanged {
      setPause(.accountChanged)
    } catch RemoteError.unauthorized {
      setPause(.sessionRequired)
    } catch {
      Self.logger.notice("Descente reportée : \(String(describing: error), privacy: .private)")
      if (error as? RemoteError)?.isRetryable ?? true {
        isPullRequested = true
        registerTransientFailure()
      }
    }
  }

  // MARK: - Réveil

  private func scheduleWake() {
    wake?.cancel()
    wake = nil
    guard dependencies.isOnline(), pause == nil else { return }
    let store = store
    let sleep = dependencies.sleep
    let now = dependencies.now
    let backoff = backoffUntil
    wake = Task { [weak self] in
      guard let due = try? await store.nextDueDate(after: now()) else {
        guard let backoff else { return }
        try? await sleep(max(0, backoff.timeIntervalSince(now())))
        if !Task.isCancelled { await self?.kick() }
        return
      }
      let target = max(due, backoff ?? due)
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
