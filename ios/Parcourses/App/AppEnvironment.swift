import Domain
import Foundation
import SwiftData

/// Dépendances de l'app, construites une fois au lancement.
final class AppEnvironment {
  /// Retenu ici : un `ModelContext` ne garde pas son conteneur, et le fetch planterait après sa libération.
  private let container: ModelContainer
  private let lists: any ListRepository
  private let products: any ProductRepository
  private let categories: any CategoryRepository
  private let entryAnalyzer: EntryAnalyzer
  /// `nil` sans configuration Supabase : l'app reste entièrement locale.
  let sync: SyncRuntime?
  private let visits: any VisitRepository
  private let stores: any StoreRepository
  private let graphs: any GraphRepository
  private let gateway: (any RemoteGateway)?
  private let location: any LocationProvider
  /// Une seule instance pour toutes les sessions : ses appels ActivityKit restent ordonnés.
  private let shoppingActivity = ActivityKitShoppingActivity()
  /// Mode courses en cours, le temps qu'il vive : « Cocher le suivant » le prévient.
  private weak var currentSession: ShoppingSession?
  /// « Cocher le suivant » de la Live Activity, branché sur `CheckNextItemRouter` au lancement.
  private(set) lazy var activityActions = ShoppingActivityActions(
    lists: lists, visits: visits, stores: stores, categories: categories, analyzer: entryAnalyzer,
    activity: shoppingActivity, session: { [weak self] in self?.currentSession })

  init(container: ModelContainer, gateway: (any RemoteGateway)? = nil) throws {
    self.container = container
    self.gateway = gateway
    location = SystemLocationProvider()
    let context = container.mainContext
    let sync = try gateway.map { try SyncRuntime(gateway: $0, container: container) }
    self.sync = sync
    let onEnqueue: () -> Void =
      sync?.enqueued ?? {
        // Sans configuration : rien à réveiller.
      }
    lists = SwiftDataListRepository(context: context, onEnqueue: onEnqueue)
    visits = SwiftDataVisitRepository(context: context, onEnqueue: onEnqueue)
    products = SwiftDataProductRepository(context: context)
    stores = SwiftDataStoreRepository(context: context)
    graphs = SwiftDataGraphRepository(context: context)
    let categories = SwiftDataCategoryRepository(context: context)
    try categories.seedIfNeeded()
    self.categories = categories
    entryAnalyzer = try EntryAnalyzer()
  }

  static func live(gateway: (any RemoteGateway)?) throws -> AppEnvironment {
    let container = try PersistenceStack.makeContainer(storage: storage())
    #if DEBUG
      try seedForUITests(container)
    #endif
    return try AppEnvironment(container: container, gateway: gateway)
  }

  #if DEBUG
    /// Tests UI : un magasin récent, et son instantané s'il est fourni.
    private static func seedForUITests(_ container: ModelContainer) throws {
      let variables = ProcessInfo.processInfo.environment
      guard let name = variables["PARCOURSES_TEST_SEED_STORE"] else { return }
      let context = container.mainContext
      let id = UUID()
      let stores = SwiftDataStoreRepository(context: context)
      try stores.upsertStore(
        id: id, name: name, chain: nil, address: "Auch", lastDistanceM: nil,
        organicAisle: variables["PARCOURSES_TEST_SEED_ORGANIC"] != nil)
      try stores.markUsed(id: id, at: .now)
      guard let json = variables["PARCOURSES_TEST_SEED_SNAPSHOT"] else { return }
      try SwiftDataGraphRepository(context: context).saveSnapshot(
        storeId: id, snapshotVersion: 1, paramsVersion: 1, confidenceQ: 0, payload: Data(json.utf8), at: .now)
    }
  #endif

  func makeListsModel() -> ListsModel {
    ListsModel(lists: lists)
  }

  func makeListDetailModel(listId: UUID) -> ListDetailModel {
    ListDetailModel(
      listId: listId, lists: lists, products: products, categories: categories, analyzer: entryAnalyzer)
  }

  func makeStorePickerModel(onFinish: @escaping (StorePickerOutcome) -> Void) -> StorePickerModel {
    StorePickerModel(location: location, gateway: gateway, stores: stores, onFinish: onFinish)
  }

  /// Visite ouverte à reprendre au lancement, vérifiée. Sa liste a pu disparaître, ou elle est restée sans coche
  /// depuis plus de 45 min : elle est alors abandonnée (close à sa dernière coche, supprimée si elle n'en a
  /// aucune, ses introuvables remis à acheter : voir `VisitRepository.abandonVisit`) et rien n'est rouvert, comme
  /// sur Android. Une visite redevenue active entre la lecture et l'abandon reste ouverte.
  func resumeShopping(now: Date = .now) async -> ShoppingSession? {
    guard let visit = try? visits.openVisit() else { return nil }
    let last = (try? visits.lastActivity(visitId: visit.id)) ?? visit.startedAt
    let listExists = (try? lists.list(id: visit.listId)) != nil
    guard listExists, now.timeIntervalSince(last) < ShoppingSession.expiry else {
      // Liste disparue : abandon sans condition. Sinon seulement si la visite est encore périmée à l'écriture.
      _ = try? visits.abandonVisit(id: visit.id, at: now, staleAfter: listExists ? ShoppingSession.expiry : 0)
      return nil
    }
    let session = makeSession(listId: visit.listId, storeId: visit.storeId)
    await session.resume(visit: visit)
    return session
  }

  /// Au lancement, après la reprise : une Live Activity qui ne suit pas la visite ouverte (visite expirée ou
  /// disparue pendant que l'app était fermée, crash) est retirée tout de suite.
  func endOrphanActivities(keeping visitId: UUID?) {
    shoppingActivity.endAll(except: visitId)
  }

  /// `storeId` à `nil` : ordre générique, sans visite (#9 §8).
  func startShopping(listId: UUID, storeId: UUID?) async -> ShoppingSession {
    let session = makeSession(listId: listId, storeId: storeId)
    await session.start()
    return session
  }

  func makeSession(listId: UUID, storeId: UUID?) -> ShoppingSession {
    var undoDelay = Duration.seconds(4)
    #if DEBUG
      // Tests UI : une capture d'écran sur un runner chargé dure plus longtemps que la bannière.
      if let seconds = ProcessInfo.processInfo.environment["PARCOURSES_TEST_UNDO_SECONDS"].flatMap(Int.init) {
        undoDelay = .seconds(seconds)
      }
    #endif
    let session = ShoppingSession(
      listId: listId, storeId: storeId, lists: lists, visits: visits, stores: stores, categories: categories,
      analyzer: entryAnalyzer, cache: GraphSnapshotCache(graphs: graphs, gateway: gateway), undoDelay: undoDelay,
      activity: shoppingActivity)
    currentSession = session
    return session
  }

  private static func storage() -> PersistenceStack.Storage {
    #if DEBUG
      // Tests UI : un fichier dédié, remis à zéro à la demande, isole le parcours et sa relance.
      let variables = ProcessInfo.processInfo.environment
      if let name = variables["PARCOURSES_TEST_STORE"] {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).store")
        if variables["PARCOURSES_TEST_STORE_RESET"] != nil {
          for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix))
          }
        }
        return .file(url)
      }
    #endif
    return .appGroup(AppGroup.identifier)
  }
}

/// Saisie analysée : quantité, libellé, forme normalisée et catégorie.
struct AnalyzedEntry: Equatable {
  let quantity: String?
  let label: String
  let normalizedName: String
  let categoryId: String
  /// « bio » ou « biologique » dans le libellé : décide du rayon, jamais de la catégorie d'une coche (#28).
  let organic: Bool
}

/// Réunit l'analyseur de saisie et le classifieur de `Domain`.
struct EntryAnalyzer {
  private let parser: QuickEntryParser
  private let classifier: CategoryClassifier

  init() throws {
    parser = try QuickEntryParser()
    classifier = try CategoryClassifier()
  }

  func analyze(_ raw: String) -> AnalyzedEntry {
    let entry = parser.parse(raw)
    let classification = classifier.classify(entry.label)
    return AnalyzedEntry(
      quantity: entry.quantity, label: entry.label, normalizedName: classification.normalized,
      categoryId: classification.categoryId, organic: classification.organic)
  }

  /// Résultat du classifieur pour un libellé déjà séparé de sa quantité.
  func classify(label: String) -> (categoryId: String, organic: Bool) {
    let classification = classifier.classify(label)
    return (classification.categoryId, classification.organic)
  }

  /// Formes à chercher pour l'autocomplétion : le texte brut (« lai ») et le singulier (« laits » → « lait »).
  func searchForms(_ label: String) -> [String] {
    let forms = [classifier.normalizer.normalizeText(label), classifier.normalizer.normalize(label)]
    return Array(Set(forms.filter { !$0.isEmpty })).sorted()
  }
}
