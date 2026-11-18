#if DEBUG
  import Foundation

  /// Captures App Store (#145), Debug seulement : les données du scénario `demo` de `UITestSharingGateway`. Noms
  /// génériques, sans marque ni enseigne (règles de l'App Store).
  ///
  /// La liste « Courses de samedi » est saisie dans le désordre. Chaque article a un produit du catalogue, et le
  /// Supermarché des Halles a un instantané appris (82 %) dont le trajet ne suit pas l'ordre générique des rayons :
  /// boulangerie à l'entrée, puis fruits et légumes, épicerie salée, petit-déjeuner, entretien, et le froid au fond
  /// (crèmerie, fromages). Le tri suit donc visiblement le graphe, pas la saisie ni les rangs des catégories.
  nonisolated enum UITestDemoData {
    struct Article {
      let index: Int
      let label: String
      let quantity: String?
      let normalizedName: String
      let categorySlug: String

      var productId: UUID { UITestDemoData.uuid("aaaaaaaa-aaaa-4aaa-8aaa", index) }
      var itemId: UUID { UITestDemoData.uuid("99999999-9999-4999-8999", index) }
    }

    struct DemoStore {
      let id: UUID
      let name: String
      let address: String
      let distanceM: Double
      /// Confiance de l'instantané servi, en millièmes ; `nil` : magasin sans instantané.
      let confidenceQ: Int?
    }

    static let listId = uuid("88888888-8888-4888-8888", 0)
    static let listName = "Courses de samedi"

    /// Ordre de saisie : celui d'une liste écrite à la va-vite.
    static let articles: [Article] = [
      Article(index: 1, label: "Lait entier", quantity: "2", normalizedName: "lait entier", categorySlug: "dairy"),
      Article(index: 2, label: "Pâtes", quantity: "500 g", normalizedName: "pate", categorySlug: "savory-grocery"),
      Article(index: 3, label: "Tomates", quantity: "6", normalizedName: "tomate", categorySlug: "produce"),
      Article(index: 4, label: "Beurre doux", quantity: "1", normalizedName: "beurre doux", categorySlug: "dairy"),
      Article(index: 5, label: "Café moulu", quantity: "1", normalizedName: "cafe moulu", categorySlug: "breakfast"),
      Article(index: 6, label: "Basilic", quantity: "1", normalizedName: "basilic", categorySlug: "produce"),
      Article(index: 7, label: "Lessive", quantity: "1", normalizedName: "lessive", categorySlug: "household"),
      Article(index: 8, label: "Comté", quantity: "200 g", normalizedName: "comte", categorySlug: "cheese"),
      Article(
        index: 9, label: "Pain de campagne", quantity: "1", normalizedName: "pain campagne", categorySlug: "bakery"),
      Article(
        index: 10, label: "Huile d'olive", quantity: "1", normalizedName: "huile olive",
        categorySlug: "savory-grocery"),
    ]

    /// Trajet appris dans le Supermarché des Halles, de l'entrée au fond du magasin (indices des articles).
    static let route = [9, 3, 6, 2, 10, 5, 7, 1, 4, 8]

    static let halles = DemoStore(
      id: uuid("bbbbbbbb-bbbb-4bbb-8bbb", 1), name: "Supermarché des Halles", address: "Avenue des Pyrénées, Auch",
      distanceM: 40, confidenceQ: 820)
    /// Magasins proches, du plus près au plus loin : le premier est proposé (« Vous êtes ici ? »).
    static let stores: [DemoStore] = [
      halles,
      DemoStore(
        id: uuid("bbbbbbbb-bbbb-4bbb-8bbb", 2), name: "Supérette du Centre", address: "Rue Dessoles, Auch",
        distanceM: 650, confidenceQ: 240),
      DemoStore(
        id: uuid("bbbbbbbb-bbbb-4bbb-8bbb", 3), name: "Épicerie du Garros", address: "Quartier du Garros, Auch",
        distanceM: 1800, confidenceQ: nil),
    ]

    /// Position du test, devant le Supermarché des Halles.
    static let location = (latitude: 43.6455, longitude: 0.5853)

    /// Instantané du graphe (`store_graph_snapshot`, format 1, `shared/reference/sort.ts`) : une chaîne d'arêtes fortes
    /// le long du trajet, une entrée forte vers la boulangerie, et quelques voisinages plus faibles qui ne la
    /// raccourcissent pas. Les autres magasins ont un graphe vide, qui ne sert qu'à leur confiance.
    static func snapshotPayload(for store: DemoStore) -> Data? {
      guard let confidenceQ = store.confidenceQ else { return nil }
      var entries: [[String: Any]] = []
      var edges: [[String: Any]] = []
      if store.id == halles.id {
        let products = route.map { index in productKey(index) }
        entries = [
          ["product_id": products[0], "weight_q": 950], ["product_id": products[1], "weight_q": 300],
        ]
        for (a, b) in zip(products, products.dropFirst()) {
          edges.append(["a": a, "b": b, "weight_q": 900])
        }
        // Voisinages secondaires : tomates et pâtes, lait et comté.
        edges.append(["a": productKey(3), "b": productKey(2), "weight_q": 150])
        edges.append(["a": productKey(1), "b": productKey(8), "weight_q": 400])
      }
      let payload: [String: Any] = [
        "format_version": 1, "snapshot_version": 7, "params_version": 1, "confidence_q": confidenceQ,
        "entries": entries, "edges": edges,
        "params": [
          "CONF_THRESHOLD_Q": 500, "COST_SCALE": 1000, "UNKNOWN_BASE": 3000, "CAT_STEP": 200,
          "TWO_OPT_MAX_PASSES": 20, "REORDER_MIN_GAIN_PCT": 10,
        ],
      ]
      return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Identifiant de produit tel que le tri le compare : UUID en minuscules.
    private static func productKey(_ index: Int) -> String {
      articles.first { $0.index == index }?.productId.uuidString.lowercased() ?? ""
    }

    fileprivate static func uuid(_ prefix: String, _ index: Int) -> UUID {
      UUID(uuidString: String(format: "%@-%012d", prefix, index)) ?? UUID()
    }
  }
#endif
