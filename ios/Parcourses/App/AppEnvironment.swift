import Domain
import Foundation
import SwiftData

extension Notification.Name {
  /// Suppression du compte : le mode courses et le choix du magasin se ferment, sans clore la visite (#68 §5.3).
  static let accountDeletionDidBegin = Notification.Name("app.parcourses.accountDeletionDidBegin")
}

/// Dépendances de l'app, construites au lancement, puis à nouveau après une suppression de compte (#68 §5.5).
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
  /// Compte de l'appareil, tel que la synchro le connaît : « vous » et les marques d'auteur (#87).
  private let accountId: () -> UUID?
  /// Une seule instance pour toutes les sessions : ses appels ActivityKit restent ordonnés.
  private let shoppingActivity: ActivityKitShoppingActivity
  /// Mode courses en cours, le temps qu'il vive : « Cocher le suivant » le prévient.
  private weak var currentSession: ShoppingSession?
  private let echoes: RecentItemWrites
  /// « Quitter la liste » : l'écran Liste revient à Mes listes sans annoncer un retrait.
  private let departures = ListDepartures()
  /// « Cocher le suivant » de la Live Activity, branché sur `CheckNextItemRouter` au lancement.
  private(set) lazy var activityActions = ShoppingActivityActions(
    lists: lists, visits: visits, stores: stores, categories: categories, analyzer: entryAnalyzer,
    activity: shoppingActivity, session: { [weak self] in self?.currentSession })

  /// `shoppingActivity` : remplacé dans les tests, qui ne doivent pas ouvrir de vraie Live Activity. `cursors` : compte
  /// des données, remplacé dans les tests de la réparation des rôles.
  init(
    container: ModelContainer, gateway: (any RemoteGateway)? = nil,
    shoppingActivity: ActivityKitShoppingActivity = ActivityKitShoppingActivity(),
    cursors: any SyncCursors = UserDefaultsSyncCursors()
  ) throws {
    self.container = container
    self.shoppingActivity = shoppingActivity
    self.gateway = gateway
    location = SystemLocationProvider()
    let context = container.mainContext
    // Écho temps réel de mes propres envois d'articles, ignoré par les signaux (#87 §6.6).
    let echoes = RecentItemWrites()
    self.echoes = echoes
    let sync = try gateway.map { try SyncRuntime(gateway: $0, container: container, echoes: echoes) }
    self.sync = sync
    let onEnqueue: () -> Void =
      sync?.enqueued ?? {
        // Sans configuration : rien à réveiller.
      }
    // Dernier compte connu : auteur d'une modification faite ici, avant même qu'elle parte (#87, lot 87.4).
    let author: () -> UUID? = { cursors.accountId }
    accountId = author
    lists = SwiftDataListRepository(context: context, onEnqueue: onEnqueue, author: author)
    visits = SwiftDataVisitRepository(context: context, onEnqueue: onEnqueue, author: author)
    products = SwiftDataProductRepository(context: context)
    stores = SwiftDataStoreRepository(context: context)
    graphs = SwiftDataGraphRepository(context: context)
    let categories = SwiftDataCategoryRepository(context: context)
    try categories.seedIfNeeded()
    self.categories = categories
    entryAnalyzer = try EntryAnalyzer()
    // Listes d'autrui passées `owner` par la migration V4→V5 : lecture seule jusqu'à la descente (#87, lot 87.4). Fait
    // ici, à la construction : avant toute reprise de visite (`resumeShopping`) et toute ouverture du mode courses. Mes
    // listes (`ownerId` = mon compte, ou `nil` après une reprise de compte) ne bougent pas. Un échec ne bloque pas le
    // lancement : la descente pose le rôle de toute façon.
    _ = try? ListRoleRepair.apply(in: context, me: cursors.accountId)
  }

  /// Environnement neuf sur le même store, après une suppression de compte : modèles d'écran, moteur de
  /// synchronisation et état en mémoire repartent de zéro. L'ancien moteur a été arrêté avant la purge. La même
  /// instance ActivityKit est gardée (ses appels restent ordonnés) et publie à nouveau.
  func restarted() throws -> AppEnvironment {
    shoppingActivity.resumePublishing()
    return try AppEnvironment(container: container, gateway: gateway, shoppingActivity: shoppingActivity)
  }

  /// Suppression du compte et de ses données, sur ce store et ce serveur.
  func makeAccountDeletion() -> AccountDeletion {
    let sync = sync
    let visits = visits
    return AccountDeletion(
      gateway: gateway, flags: UserDefaultsAccountDeletionFlagStore(), purge: Self.makePurge(container),
      accountKind: { UserDefaultsAccountKindStore().kind },
      isOnline: { sync?.isOnline ?? true }, hasOpenVisit: { (try? visits.openVisit()) != nil },
      beginBackgroundWork: {
        let activity = BackgroundActivity(name: "account-deletion")
        // À l'expiration, le drapeau reste : la suppression reprendra au lancement suivant.
        activity.begin {}
        return { activity.end() }
      })
  }

  /// Purge de l'appareil. Tests UI : purges forcées en échec (#129).
  private static func makePurge(_ container: ModelContainer) -> LocalDataPurge {
    #if DEBUG
      return LocalDataPurge(container: container, injectedFailure: UITestPurgeFailures.inject)
    #else
      return LocalDataPurge(container: container)
    #endif
  }

  /// Compte de l'appareil (#87) : liaison d'une adresse, connexion, déconnexion.
  func makeAccountSession(operations: AccountOperationQueue = AccountOperationQueue()) -> AccountSession {
    let sync = sync
    let container = container
    let cursors = UserDefaultsSyncCursors()
    // Entrées `pending` et `failed` : toutes celles qui restent dans la file seraient perdues.
    let pendingChanges: () -> Int = { (try? container.mainContext.fetchCount(FetchDescriptor<OutboxEntry>())) ?? 0 }
    let link = AccountLink.Dependencies(
      isOnline: { sync?.isOnline ?? true },
      resendableLists: { accountId in
        // Même compte (reconnexion) : rien n'est renvoyé.
        guard cursors.accountId != accountId else { return 0 }
        return (try? AccountRekey.resendCount(in: container.mainContext, previousAccountId: cursors.accountId)) ?? 0
      },
      synchronize: { await sync?.synchronize() },
      sessionDidChange: { sync?.sessionDidChange() },
      previousAccountId: { cursors.accountId },
      pendingChanges: pendingChanges,
      suspendSync: { await sync?.suspend() },
      resumeSync: { await sync?.resumeAndWait() })
    return AccountSession(
      gateway: gateway, kinds: UserDefaultsAccountKindStore(), purge: Self.makePurge(container),
      cursors: cursors, operations: operations,
      dependencies: AccountSession.Dependencies(
        isOnline: { sync?.isOnline ?? true },
        pendingChanges: pendingChanges,
        sessionDidChange: { sync?.sessionDidChange() }, link: link))
  }

  /// Étape 2 de la suppression : rien ne reste affiché hors de l'app (nom de liste, magasin, article suivant), et
  /// plus rien n'écrit dans le store. La visite ouverte n'est pas close : elle va disparaître.
  func endShoppingForDeletion() {
    shoppingActivity.endEverything()
    CheckNextItemRouter.handler = nil
    currentSession = nil
    NotificationCenter.default.post(name: .accountDeletionDidBegin, object: nil)
  }

  /// Suppression abandonnée ou refusée : « Cocher le suivant » et la Live Activity reviennent.
  func resumeShoppingAfterDeletion() {
    shoppingActivity.resumePublishing()
    CheckNextItemRouter.handler = activityActions
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
      let stores = SwiftDataStoreRepository(context: context)
      // Store conservé d'un lancement à l'autre (App Group) : le même magasin est réutilisé, jamais dupliqué.
      let id = try stores.recentStores(limit: 100).first { $0.name == name }?.id ?? UUID()
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
    ListsModel(lists: lists, accountId: accountId)
  }

  func makeListDetailModel(listId: UUID) -> ListDetailModel {
    ListDetailModel(
      listId: listId, lists: lists, products: products, categories: categories, analyzer: entryAnalyzer,
      accountId: accountId, departures: departures)
  }

  /// Partage (#87, lot 87.4) : invitations, liens, feuille « Partager », signaux temps réel.
  func makeSharingCenter(account: AccountSession?) -> SharingCenter {
    let sync = sync
    let lists = lists
    let accountId = accountId
    let echoes = echoes
    let departures = departures
    var monitorsNetwork = true
    #if DEBUG
      // Tests UI : réseau imposé par le scénario.
      if ProcessInfo.processInfo.environment["PARCOURSES_TEST_SHARING"] != nil { monitorsNetwork = false }
    #endif
    return SharingCenter(
      gateway: gateway, transport: gateway as? any RealtimeTransport,
      dependencies: SharingCenter.Dependencies(
        isEmailAccount: { [weak account] in account?.kind == .email && account?.needsSignIn == false },
        accountEmail: { [weak account] in account?.email },
        synchronize: { await sync?.synchronize() },
        requestPull: { sync?.foreground() },
        listExists: { (try? lists.list(id: $0)) != nil },
        forgetList: { id in
          // Noté avant l'oubli : l'écran Liste, rechargé par la notification, sait que c'est un départ.
          departures.record(id)
          try? lists.forgetList(id: id)
          NotificationCenter.default.post(name: .syncDidChangeData, object: nil)
        },
        accountId: accountId, echoDelay: { echoes.echoDelay($0) }),
      monitorsNetwork: monitorsNetwork)
  }

  func makeStorePickerModel(onFinish: @escaping (StorePickerOutcome) -> Void) -> StorePickerModel {
    StorePickerModel(location: location, gateway: gateway, stores: stores, onFinish: onFinish)
  }

  /// Visite ouverte à reprendre au lancement, vérifiée. Sa liste a pu disparaître, ou elle est restée sans coche
  /// depuis plus de 45 min : elle est alors abandonnée (close à sa dernière coche, supprimée si elle n'en a
  /// aucune et n'est jamais partie, ses introuvables remis à acheter : voir `VisitRepository.abandonVisit`) et rien
  /// n'est rouvert, comme sur Android. Une visite redevenue active entre la lecture et l'abandon reste ouverte.
  /// Liste passée en lecture seule (#87, Q5) : abandonnée comme une liste disparue, un lecteur ne fait pas de courses.
  func resumeShopping(now: Date = .now) async -> ShoppingSession? {
    guard let visit = try? visits.openVisit() else { return nil }
    let last = (try? visits.lastActivity(visitId: visit.id)) ?? visit.startedAt
    let list = try? lists.list(id: visit.listId)
    let canShop = list.map { SharingDecisions.roleCapabilities($0.role).canShop } ?? false
    guard canShop, now.timeIntervalSince(last) < ShoppingSession.expiry else {
      // Liste disparue ou en lecture seule : abandon sans condition. Sinon seulement si la visite est encore périmée
      // à l'écriture.
      _ = try? visits.abandonVisit(id: visit.id, at: now, staleAfter: canShop ? ShoppingSession.expiry : 0)
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

  /// La liste existe et mon rôle permet les courses (Q5) : relu au moment de partir, le rôle a pu baisser pendant le
  /// choix du magasin.
  func canShop(listId: UUID) -> Bool {
    guard let list = try? lists.list(id: listId) else { return false }
    return SharingDecisions.roleCapabilities(list.role).canShop
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
      activity: shoppingActivity, accountId: accountId)
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

  /// Libellé modifié dans le panneau de l'article (#110) : classé tel quel, sans en extraire de quantité (« 2 lait »
  /// tapé dans le champ Libellé reste le libellé « 2 lait »).
  func analyze(label: String) -> AnalyzedEntry {
    let classification = classifier.classify(label)
    return AnalyzedEntry(
      quantity: nil, label: label, normalizedName: classification.normalized,
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
