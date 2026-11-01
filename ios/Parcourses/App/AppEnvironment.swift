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

  init(container: ModelContainer, gateway: (any RemoteGateway)? = nil) throws {
    self.container = container
    let context = container.mainContext
    let sync = try gateway.map { try SyncRuntime(gateway: $0, container: container) }
    self.sync = sync
    lists = SwiftDataListRepository(context: context, onEnqueue: sync?.enqueued ?? {})
    products = SwiftDataProductRepository(context: context)
    let categories = SwiftDataCategoryRepository(context: context)
    try categories.seedIfNeeded()
    self.categories = categories
    entryAnalyzer = try EntryAnalyzer()
  }

  static func live(gateway: (any RemoteGateway)?) throws -> AppEnvironment {
    try AppEnvironment(container: PersistenceStack.makeContainer(storage: storage()), gateway: gateway)
  }

  func makeListsModel() -> ListsModel {
    ListsModel(lists: lists)
  }

  func makeListDetailModel(listId: UUID) -> ListDetailModel {
    ListDetailModel(
      listId: listId, lists: lists, products: products, categories: categories, analyzer: entryAnalyzer)
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
      categoryId: classification.categoryId)
  }

  /// Formes à chercher pour l'autocomplétion : le texte brut (« lai ») et le singulier (« laits » → « lait »).
  func searchForms(_ label: String) -> [String] {
    let forms = [classifier.normalizer.normalizeText(label), classifier.normalizer.normalize(label)]
    return Array(Set(forms.filter { !$0.isEmpty })).sorted()
  }
}
