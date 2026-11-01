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

  /// Visite ouverte à reprendre au lancement, en la vérifiant : sa liste a pu disparaître.
  func resumeShopping() async -> ShoppingSession? {
    guard let visit = try? visits.openVisit() else { return nil }
    guard (try? lists.list(id: visit.listId)) != nil else {
      try? visits.closeVisit(id: visit.id, at: .now)
      return nil
    }
    let session = makeSession(listId: visit.listId, storeId: visit.storeId)
    await session.resume(visit: visit)
    return session
  }

  /// `storeId` à `nil` : ordre générique, sans visite (#9 §8).
  func startShopping(listId: UUID, storeId: UUID?) async -> ShoppingSession {
    let session = makeSession(listId: listId, storeId: storeId)
    await session.start()
    return session
  }

  private func makeSession(listId: UUID, storeId: UUID?) -> ShoppingSession {
    ShoppingSession(
      listId: listId, storeId: storeId, lists: lists, visits: visits, stores: stores, categories: categories,
      analyzer: entryAnalyzer, cache: GraphSnapshotCache(graphs: graphs, gateway: gateway))
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
