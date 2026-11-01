import Domain
import Foundation
import Observation
import SortEngine

/// Ce que l'app sait du trajet dans ce magasin (#6).
enum RouteKnowledge: Equatable {
  /// Pas de magasin choisi.
  case noStore
  /// Aucun instantané : ordre générique.
  case unknown
  /// Graphe trop peu fiable : ordre générique. Confiance en pourcentage.
  case learning(Int)
  case learned(Int)
}

/// Une ligne du mode courses.
struct ShoppingRow: Identifiable, Equatable {
  let id: UUID
  let label: String
  let quantity: String?
  let isChecked: Bool

  var accessibilityLabel: String {
    [label, quantity].compactMap(\.self).joined(separator: ", ")
  }
}

/// Dernière action, annulable 4 s.
struct ShoppingUndo: Equatable {
  enum Kind: Equatable {
    case check
    case notFound
  }

  let kind: Kind
  let itemId: UUID
  let label: String
  /// Coche locale à retirer ; `nil` sans visite.
  let checkId: UUID?
  /// Place de la ligne avant l'action.
  let index: Int

  var message: String {
    switch kind {
    case .check: "\(label) coché"
    case .notFound: "\(label) introuvable"
    }
  }
}

/// Résumé de fin de visite.
struct ShoppingSummary: Equatable {
  let checkedCount: Int
  let minutes: Int
  let storeName: String?
  let knowledge: RouteKnowledge
}

/// Mode courses (#9 §6.3) : ordre affiché, coches, introuvables, ajouts, annulation et fin.
/// Tout s'écrit d'abord en local : ni le réseau ni la session ne sont jamais attendus pour cocher.
@Observable
final class ShoppingSession: Identifiable {
  /// Sans coche depuis ce délai, la visite se termine au retour au premier plan (#9 §5.5).
  static let expiry: TimeInterval = 45 * 60

  nonisolated let id = UUID()
  private(set) var name = ""
  private(set) var storeName: String?
  /// À acheter, dans l'ordre affiché. Une ligne juste cochée y reste le temps du délai d'inactivité.
  private(set) var toBuy: [ShoppingRow] = []
  private(set) var basket: [ShoppingRow] = []
  private(set) var notFound: [ShoppingRow] = []
  private(set) var knowledge = RouteKnowledge.noStore
  private(set) var undo: ShoppingUndo?
  /// Article tout juste ajouté, à repérer pendant 300 ms.
  private(set) var highlightedItemId: UUID?
  /// Visite terminée d'office après 45 min : il ne reste qu'à décider des articles restants.
  private(set) var expired = false
  private(set) var summary: ShoppingSummary?
  private(set) var visitId: UUID?
  private(set) var mode = SortOutput.Mode.fallback
  var input = ""
  var errorMessage: String?

  private var listId: UUID
  private var remapObserver: IdentifierRemapObserver?
  private let storeId: UUID?
  private let lists: any ListRepository
  private let visits: any VisitRepository
  private let stores: any StoreRepository
  private let categoryRepository: any CategoryRepository
  private let analyzer: EntryAnalyzer
  private let cache: GraphSnapshotCache
  private let now: () -> Date
  private let settleDelay: Duration
  private let undoDelay: Duration
  private let highlightDelay: Duration
  private let preloadTimeout: Duration
  private let sendMargin: Duration

  private var storeOrganicAisle = false
  private var sortCategories: [SortCategory] = []
  private var current: LoadedSnapshot?
  /// Arrivé pendant la visite : s'applique à la coche suivante, jamais spontanément (#9 §5.4).
  private var pendingSnapshot: LoadedSnapshot?
  /// Même règle pour le rayon bio venu du serveur : la liste ne bouge pas d'elle-même.
  private var pendingOrganicAisle: Bool?
  /// Lignes cochées qui restent à leur place jusqu'au prochain tri (600 ms).
  private var settlingIds: Set<UUID> = []
  private var startedAt = Date.distantPast
  /// Fin réelle d'une visite expirée : le temps passé ailleurs ne compte pas dans le résumé.
  private var expiredAt: Date?
  private var isScrolling = false
  private var isEditing = false
  private var hasUnsettledChange = false
  private var settleTask: Task<Void, Never>?
  private var undoTask: Task<Void, Never>?
  private var highlightTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var refreshFinished = false
  private var refreshWaiter: CheckedContinuation<Void, Never>?
  /// Écarte le résultat d'un tri devenu périmé pendant son calcul.
  private var generation = 0

  init(
    listId: UUID, storeId: UUID?, lists: any ListRepository, visits: any VisitRepository,
    stores: any StoreRepository, categories: any CategoryRepository, analyzer: EntryAnalyzer,
    cache: GraphSnapshotCache, now: @escaping () -> Date = { .now }, settleDelay: Duration = .milliseconds(600),
    undoDelay: Duration = .seconds(4), highlightDelay: Duration = .milliseconds(300),
    preloadTimeout: Duration = .seconds(3), sendMargin: Duration = .seconds(1)
  ) {
    self.listId = listId
    self.storeId = storeId
    self.lists = lists
    self.visits = visits
    self.stores = stores
    categoryRepository = categories
    self.analyzer = analyzer
    self.cache = cache
    self.now = now
    self.settleDelay = settleDelay
    self.undoDelay = undoDelay
    self.highlightDelay = highlightDelay
    self.preloadTimeout = preloadTimeout
    self.sendMargin = sendMargin
    remapObserver = IdentifierRemapObserver { [weak self] in self?.apply($0) }
  }

  /// Les données ont changé d'identifiants (perte de session) : la visite continue, tout le reste suit.
  /// Un tri déjà lancé porte les anciens identifiants : il est écarté.
  func apply(_ remap: IdentifierRemap) {
    listId = remap[listId]
    visitId = visitId.map { remap[$0] }
    settlingIds = Set(settlingIds.map { remap[$0] })
    highlightedItemId = highlightedItemId.map { remap[$0] }
    undo = undo.map {
      ShoppingUndo(
        kind: $0.kind, itemId: remap[$0.itemId], label: $0.label, checkId: $0.checkId.map { remap[$0] }, index: $0.index
      )
    }
    let remapped: ([ShoppingRow]) -> [ShoppingRow] = { rows in
      rows.map { ShoppingRow(id: remap[$0.id], label: $0.label, quantity: $0.quantity, isChecked: $0.isChecked) }
    }
    toBuy = remapped(toBuy)
    basket = remapped(basket)
    notFound = remapped(notFound)
    generation += 1
    if hasUnsettledChange { scheduleSettle() }
  }

  // MARK: - Ouverture

  /// Nouvelle visite. Elle ne reste qu'en local jusqu'à la première coche.
  func start() async {
    startedAt = now()
    await prepare()
    guard let storeId else { return }
    perform {
      // `listWasSorted` : le mode du début de visite, celui que la personne a réellement suivi (#9 §6.3).
      let visit = try visits.startVisit(
        storeId: storeId, listId: listId, listWasSorted: mode == .learned, at: startedAt)
      visitId = visit.id
      startedAt = visit.startedAt
    }
  }

  /// Reprise au lancement. La visite peut avoir expiré pendant que l'app était fermée.
  func resume(visit: Visit) async {
    startedAt = visit.startedAt
    visitId = visit.id
    await prepare()
    foregrounded()
  }

  private func prepare() async {
    perform {
      name = try lists.list(id: listId)?.name ?? ""
      sortCategories = try categoryRepository.categories().map { SortCategory(id: $0.id, rank: Int64($0.rank)) }
      if let storeId, let store = try stores.store(id: storeId) {
        storeName = store.name
        storeOrganicAisle = store.organicAisle
      }
    }
    if let storeId {
      current = cache.cached(storeId: storeId)
      await preloadSnapshot(storeId: storeId)
    }
    refreshKnowledge()
    reloadRows()
    await sortNow(previous: nil)
  }

  /// Attend le serveur au plus `preloadTimeout`. Au-delà, la réponse attend la première coche dans `pendingSnapshot`.
  private func preloadSnapshot(storeId: UUID) async {
    let cache = cache
    let stores = stores
    refreshTask = Task {
      // Le cache peut dater : un magasin d'avant la migration V2 y est toujours « sans rayon bio ».
      if let gateway = cache.gateway, let organic = try? await gateway.storeOrganicAisle(id: storeId) {
        try? stores.updateOrganicAisle(id: storeId, organicAisle: organic)
        pendingOrganicAisle = organic
      }
      pendingSnapshot = try? await cache.refresh(storeId: storeId)
      refreshFinished = true
      resumeRefreshWaiter()
    }
    if !refreshFinished {
      await withCheckedContinuation { continuation in
        refreshWaiter = continuation
        Task { [preloadTimeout] in
          try? await Task.sleep(for: preloadTimeout)
          resumeRefreshWaiter()
        }
      }
    }
    adoptPendingSnapshot()
  }

  private func resumeRefreshWaiter() {
    refreshWaiter?.resume()
    refreshWaiter = nil
  }

  private func adoptPendingSnapshot() {
    if let pendingOrganicAisle {
      storeOrganicAisle = pendingOrganicAisle
      self.pendingOrganicAisle = nil
    }
    guard let pendingSnapshot else { return }
    current = pendingSnapshot
    self.pendingSnapshot = nil
    refreshKnowledge()
  }

  private func refreshKnowledge() {
    guard storeId != nil else {
      knowledge = .noStore
      return
    }
    guard let current, current.snapshot.confidenceQ > 0 else {
      knowledge = .unknown
      return
    }
    let percent = Int(current.snapshot.confidenceQ / 10)
    knowledge =
      current.snapshot.confidenceQ >= current.params.confThresholdQ ? .learned(percent) : .learning(percent)
  }

  // MARK: - Actions

  func toggle(_ row: ShoppingRow) {
    if row.isChecked { uncheck(row) } else { check(row) }
  }

  private func check(_ row: ShoppingRow) {
    guard let item = item(row.id), let index = toBuy.firstIndex(where: { $0.id == row.id }) else { return }
    let date = now()
    var checkId: UUID?
    let succeeded = perform {
      if let visitId {
        checkId =
          try visits.checkItem(
            visitId: visitId, itemId: row.id, subject: Self.subject(of: item, analyzer: analyzer), checkedAt: date,
            // Marge : l'envoi ne doit pas partir pendant que la bannière « Annuler » est encore affichée.
            sendAfter: (undoDelay + sendMargin).timeInterval
          ).id
      } else {
        try lists.setChecked(itemId: row.id, checkedAt: date, at: date)
      }
    }
    guard succeeded else { return }
    // La ligne reste à sa place jusqu'au prochain tri : elle ne bouge jamais sous le doigt.
    settlingIds.insert(row.id)
    toBuy[index] = ShoppingRow(id: row.id, label: row.label, quantity: row.quantity, isChecked: true)
    adoptPendingSnapshot()
    offerUndo(ShoppingUndo(kind: .check, itemId: row.id, label: row.label, checkId: checkId, index: index))
    scheduleSettle()
  }

  /// Ce que désigne la coche : le produit, sinon la catégorie du classifieur, jamais le rayon bio (#28).
  static func subject(of item: ListItem, analyzer: EntryAnalyzer) -> CheckSubject {
    if let productId = item.productId { return .product(productId) }
    if item.categoryId == organicCategoryId { return .category(analyzer.classify(label: item.label).categoryId) }
    return .category(item.categoryId)
  }

  /// Nouvel appui sur une ligne cochée. Une coche déjà partie reste au serveur, qui ne retient que la première
  /// de chaque produit : seule la liste change alors.
  private func uncheck(_ row: ShoppingRow) {
    let date = now()
    let succeeded = perform {
      if let visitId {
        let check = try visits.checks(visitId: visitId).last { $0.itemId == row.id }
        try visits.uncheckItem(itemId: row.id, checkId: check?.id, at: date)
      } else {
        try lists.setChecked(itemId: row.id, checkedAt: nil, at: date)
      }
    }
    guard succeeded else { return }
    settlingIds.remove(row.id)
    if undo?.itemId == row.id { clearUndo() }
    reloadRows()
    scheduleSettle()
  }

  func markNotFound(_ row: ShoppingRow) {
    let index = toBuy.firstIndex { $0.id == row.id } ?? 0
    let date = now()
    guard perform({ try lists.setNotFound(itemId: row.id, notFoundAt: date, at: date) }) else { return }
    reloadRows()
    offerUndo(ShoppingUndo(kind: .notFound, itemId: row.id, label: row.label, checkId: nil, index: index))
    scheduleSettle()
  }

  /// Remet un article introuvable dans ce qu'il reste à acheter.
  func restore(_ row: ShoppingRow) {
    let date = now()
    guard perform({ try lists.setNotFound(itemId: row.id, notFoundAt: nil, at: date) }) else { return }
    reloadRows()
    scheduleSettle()
  }

  /// Ajout en route : l'article prend sa place estimée sans déplacer les autres, le temps de la saisie.
  func submit() async {
    let entry = analyzer.analyze(input)
    guard !entry.label.isEmpty else { return }
    var added: UUID?
    let succeeded = perform {
      added =
        try lists.addItem(
          listId: listId, label: entry.label, normalizedName: entry.normalizedName, quantity: entry.quantity,
          productId: nil, categoryId: entry.categoryId, at: now()
        ).id
    }
    guard succeeded, let added else { return }
    input = ""
    // Lignes juste cochées comprises : elles gardent leur place.
    let previous = toBuy.map(\.id)
    reloadRows()
    let estimated = await computeOrder(previous: previous)
    let predecessors = Set(estimated.prefix { $0 != added })
    var order = previous
    order.insert(added, at: (order.lastIndex { predecessors.contains($0) } ?? -1) + 1)
    arrange(order)
    highlight(added)
  }

  func performUndo() {
    guard let undo else { return }
    clearUndo()
    let date = now()
    let succeeded = perform {
      switch undo.kind {
      case .check:
        if undo.checkId != nil {
          try visits.uncheckItem(itemId: undo.itemId, checkId: undo.checkId, at: date)
        } else {
          try lists.setChecked(itemId: undo.itemId, checkedAt: nil, at: date)
        }
      case .notFound:
        try lists.setNotFound(itemId: undo.itemId, notFoundAt: nil, at: date)
      }
    }
    guard succeeded else { return }
    settlingIds.remove(undo.itemId)
    // La ligne reprend sa place : l'annulation n'est pas un nouveau trajet.
    var order = toBuy.map(\.id).filter { $0 != undo.itemId }
    order.insert(undo.itemId, at: min(undo.index, order.count))
    reloadRows()
    arrange(order)
    // Le tri attendu par une autre coche reste dû ; s'il n'y en a pas, l'annulation ne déclenche aucun trajet.
    if settlingIds.isEmpty {
      settleTask?.cancel()
      generation += 1
      hasUnsettledChange = false
    } else {
      scheduleSettle()
    }
  }

  // MARK: - Tri

  func setScrolling(_ value: Bool) {
    isScrolling = value
    interactionChanged()
  }

  func setEditing(_ value: Bool) {
    isEditing = value
    interactionChanged()
  }

  /// Une interaction suspend un tri en attente ; le délai repart de zéro à sa fin.
  private func interactionChanged() {
    if hasUnsettledChange { scheduleSettle() }
  }

  /// Rien ne bouge pendant un défilement ou une saisie : le tri attend 600 ms d'inactivité (#6).
  private func scheduleSettle() {
    hasUnsettledChange = true
    settleTask?.cancel()
    settleTask = nil
    // Un tri déjà lancé ne connaît pas ce changement : son résultat est écarté.
    generation += 1
    // Un clavier resté ouvert sans texte ne doit pas figer la liste : seule une saisie en cours suspend le tri.
    guard !isScrolling, !(isEditing && !input.isEmpty) else { return }
    settleTask = Task { [settleDelay] in
      try? await Task.sleep(for: settleDelay)
      guard !Task.isCancelled else { return }
      await sortNow(previous: toBuy.filter { !$0.isChecked }.map(\.id))
    }
  }

  /// Attend la fin du tri en cours : pour les tests.
  func waitUntilSettled() async {
    await settleTask?.value
  }

  private func sortNow(previous: [UUID]?) async {
    generation += 1
    let mine = generation
    let order = await computeOrder(previous: previous)
    guard mine == generation else { return }
    hasUnsettledChange = false
    settlingIds.removeAll()
    reloadRows()
    arrange(order)
  }

  /// Calcul hors du fil principal (#9 §3.3). Une entrée refusée laisse l'ordre actuel, sans jamais bloquer la coche.
  private func computeOrder(previous: [UUID]?) async -> [UUID] {
    let items = (try? remainingItems()) ?? []
    let input = sortInput(items: items, previous: previous)
    do {
      let output = try await Self.runSort(input)
      mode = output.mode
      return output.order.compactMap(UUID.init(uuidString:))
    } catch {
      mode = .fallback
      return previous ?? items.map(\.id)
    }
  }

  @concurrent private nonisolated static func runSort(_ input: SortInput) async throws -> SortOutput {
    try sortItems(input)
  }

  private func sortInput(items: [ListItem], previous: [UUID]?) -> SortInput {
    SortInput(
      params: current?.params ?? .default, categories: sortCategories, snapshot: current?.snapshot,
      items: items.map { item in
        // Le rayon bio n'existe que pour le tri, et seulement si le magasin en a un (#28).
        let organic = analyzer.classify(label: item.label).organic
        return SortItem(
          id: item.id.sortId, productId: item.productId?.sortId,
          categoryId: effectiveCategory(
            categoryId: item.categoryId, organic: organic, storeOrganicAisle: storeOrganicAisle),
          normalizedName: item.normalizedName)
      }, start: resolvedStart(), previousOrder: previous?.map(\.sortId))
  }

  /// Dernier article coché de cette visite ayant un produit, sinon l'entrée du magasin.
  private func resolvedStart() -> SortStart {
    let items = (try? lists.items(listId: listId)) ?? []
    let last =
      items
      .filter { $0.productId != nil && ($0.checkedAt ?? .distantPast) >= startedAt }
      .max { ($0.checkedAt ?? .distantPast) < ($1.checkedAt ?? .distantPast) }
    return last?.productId.map { .product($0.sortId) } ?? .entry
  }

  private func remainingItems() throws -> [ListItem] {
    try lists.items(listId: listId).filter { $0.checkedAt == nil && $0.notFoundAt == nil }
  }

  /// Applique un ordre aux lignes déjà lues. Ce qui n'y figure pas garde sa place relative, à la fin.
  private func arrange(_ order: [UUID]) {
    toBuy = Self.ordered(toBuy, by: order)
  }

  private static func ordered(_ rows: [ShoppingRow], by order: [UUID]) -> [ShoppingRow] {
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    return rows.enumerated()
      .sorted { (rank[$0.element.id] ?? order.count + $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset) }
      .map(\.element)
  }

  /// Relit la liste en gardant l'ordre affiché. Une ligne juste cochée ne passe au panier qu'au tri suivant.
  private func reloadRows() {
    let items = (try? lists.items(listId: listId)) ?? []
    let rows = items.map {
      (item: $0, row: ShoppingRow(id: $0.id, label: $0.label, quantity: $0.quantity, isChecked: $0.checkedAt != nil))
    }
    let settling = settlingIds
    toBuy = Self.ordered(
      rows.filter { settling.contains($0.row.id) || ($0.item.checkedAt == nil && $0.item.notFoundAt == nil) }.map(
        \.row),
      by: toBuy.map(\.id))
    basket = rows.filter { $0.item.checkedAt != nil && !settling.contains($0.row.id) }
      .sorted { ($0.item.checkedAt ?? .distantPast) > ($1.item.checkedAt ?? .distantPast) }.map(\.row)
    notFound = rows.filter { $0.item.checkedAt == nil && $0.item.notFoundAt != nil }.map(\.row)
  }

  /// Après une descente : les changements venus d'ailleurs, sans toucher à une ligne en attente.
  func syncDidChange() {
    guard !hasUnsettledChange, summary == nil, !expired else { return }
    reloadRows()
    scheduleSettle()
  }

  // MARK: - Annulation

  private func offerUndo(_ action: ShoppingUndo) {
    undoTask?.cancel()
    undo = action
    undoTask = Task { [undoDelay] in
      try? await Task.sleep(for: undoDelay)
      guard !Task.isCancelled else { return }
      undo = nil
    }
  }

  private func clearUndo() {
    undoTask?.cancel()
    undo = nil
  }

  private func highlight(_ id: UUID) {
    highlightedItemId = id
    highlightTask?.cancel()
    highlightTask = Task { [highlightDelay] in
      try? await Task.sleep(for: highlightDelay)
      guard !Task.isCancelled else { return }
      highlightedItemId = nil
    }
  }

  // MARK: - Fin

  /// Articles ni cochés ni décidés : la sheet de fin demande s'il faut les garder.
  var remainingCount: Int {
    toBuy.filter { !$0.isChecked }.count + notFound.count
  }

  var isEverythingChecked: Bool {
    remainingCount == 0 && !(toBuy.isEmpty && basket.isEmpty)
  }

  /// Au retour au premier plan : 45 min sans coche terminent la visite. La date de fin est celle de la dernière
  /// coche, pas celle du retour, qui allongerait la visite de tout le temps passé ailleurs.
  func foregrounded() {
    guard let visitId, !expired, summary == nil else { return }
    let lastActivity = (try? visits.checks(visitId: visitId).last?.checkedAt) ?? startedAt
    guard now().timeIntervalSince(lastActivity) >= Self.expiry else { return }
    guard perform({ try visits.closeVisit(id: visitId, at: lastActivity) }) else { return }
    self.visitId = nil
    expiredAt = lastActivity
    expired = true
    settlingIds.removeAll()
    clearUndo()
    reloadRows()
    if remainingCount == 0 { finish(keepRemaining: true) }
  }

  /// Termine les courses. `keepRemaining` : les articles restants attendent la prochaine fois, sinon ils
  /// quittent la liste.
  func finish(keepRemaining: Bool) {
    let date = now()
    settleTask?.cancel()
    refreshTask?.cancel()
    generation += 1
    settlingIds.removeAll()
    clearUndo()
    reloadRows()
    let succeeded = perform {
      if keepRemaining {
        for row in notFound { try lists.setNotFound(itemId: row.id, notFoundAt: nil, at: date) }
      } else {
        for row in toBuy + notFound { try lists.deleteItem(id: row.id) }
      }
      if let visitId { try visits.closeVisit(id: visitId, at: date) }
    }
    guard succeeded else { return }
    visitId = nil
    let checked = ((try? lists.items(listId: listId)) ?? []).filter { ($0.checkedAt ?? .distantPast) >= startedAt }
    let end = expiredAt ?? date
    summary = ShoppingSummary(
      checkedCount: checked.count, minutes: max(1, Int((end.timeIntervalSince(startedAt) / 60).rounded())),
      storeName: storeName, knowledge: knowledge)
  }

  // MARK: - Outils

  private func item(_ id: UUID) -> ListItem? {
    (try? lists.items(listId: listId))?.first { $0.id == id }
  }

  @discardableResult private func perform(_ work: () throws -> Void) -> Bool {
    do {
      try work()
      return true
    } catch {
      errorMessage = "L'opération a échoué : \(error.localizedDescription)"
      return false
    }
  }
}

extension UUID {
  /// Le tri n'accepte que des identifiants en minuscules, et `uuidString` est en majuscules.
  fileprivate var sortId: String { uuidString.lowercased() }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
