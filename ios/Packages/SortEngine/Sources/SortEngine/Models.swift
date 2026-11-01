// Modèles d'entrée et de sortie du tri. Leur forme JSON est exactement celle de `input` et de
// `expected` d'un vecteur de `shared/test-vectors/sort/` (#5 §4), d'où les clés snake_case.

/// Paramètres de l'algorithme (#5 §2.6). Tous les nombres sont des entiers.
public struct SortParams: Sendable, Equatable, Codable {
  /// Confiance minimale du graphe (en millièmes) pour utiliser le mode appris.
  public var confThresholdQ: Int64
  /// Échelle du coût d'une arête : `edgeCost(w) = COST_SCALE × 1000 / (1000 + w)`.
  public var costScale: Int64
  /// Coût de base du repli par catégorie.
  public var unknownBase: Int64
  /// Coût ajouté par écart d'une catégorie (indice ordinal).
  public var catStep: Int64
  /// Nombre maximal de passes 2-opt (0 : glouton seul).
  public var twoOptMaxPasses: Int64
  /// Gain minimal, en pourcentage, pour abandonner l'ordre précédent.
  public var reorderMinGainPct: Int64

  /// Valeurs par défaut de #5, identiques à `DEFAULT_PARAMS` de la référence.
  public static let `default` = SortParams(
    confThresholdQ: 500, costScale: 1000, unknownBase: 3000, catStep: 200,
    twoOptMaxPasses: 20, reorderMinGainPct: 10)

  public init(
    confThresholdQ: Int64, costScale: Int64, unknownBase: Int64, catStep: Int64,
    twoOptMaxPasses: Int64, reorderMinGainPct: Int64
  ) {
    self.confThresholdQ = confThresholdQ
    self.costScale = costScale
    self.unknownBase = unknownBase
    self.catStep = catStep
    self.twoOptMaxPasses = twoOptMaxPasses
    self.reorderMinGainPct = reorderMinGainPct
  }

  enum CodingKeys: String, CodingKey {
    case confThresholdQ = "CONF_THRESHOLD_Q"
    case costScale = "COST_SCALE"
    case unknownBase = "UNKNOWN_BASE"
    case catStep = "CAT_STEP"
    case twoOptMaxPasses = "TWO_OPT_MAX_PASSES"
    case reorderMinGainPct = "REORDER_MIN_GAIN_PCT"
  }
}

/// Catégorie : seul l'ordre `(rank, id)` compte, jamais l'échelle de `rank`.
public struct SortCategory: Sendable, Equatable, Codable {
  public var id: String
  public var rank: Int64

  public init(id: String, rank: Int64) {
    self.id = id
    self.rank = rank
  }
}

/// Lien appris entre l'entrée du magasin et un produit.
public struct SnapshotEntry: Sendable, Equatable, Codable {
  public var productId: String
  public var weightQ: Int64

  public init(productId: String, weightQ: Int64) {
    self.productId = productId
    self.weightQ = weightQ
  }

  enum CodingKeys: String, CodingKey {
    case productId = "product_id"
    case weightQ = "weight_q"
  }
}

/// Arête non orientée du graphe de voisinage entre deux produits.
public struct SnapshotEdge: Sendable, Equatable, Codable {
  public var a: String
  public var b: String
  public var weightQ: Int64

  public init(a: String, b: String, weightQ: Int64) {
    self.a = a
    self.b = b
    self.weightQ = weightQ
  }

  enum CodingKeys: String, CodingKey {
    case a, b
    case weightQ = "weight_q"
  }
}

/// Copie locale du graphe d'un magasin, telle que publiée par le serveur.
public struct SortSnapshot: Sendable, Equatable, Codable {
  public var confidenceQ: Int64
  public var entries: [SnapshotEntry]
  public var edges: [SnapshotEdge]

  public init(confidenceQ: Int64, entries: [SnapshotEntry], edges: [SnapshotEdge]) {
    self.confidenceQ = confidenceQ
    self.entries = entries
    self.edges = edges
  }

  enum CodingKeys: String, CodingKey {
    case confidenceQ = "confidence_q"
    case entries, edges
  }
}

/// Article restant à trier.
public struct SortItem: Sendable, Equatable, Codable {
  public var id: String
  /// Produit du catalogue ; `nil` pour un texte libre.
  public var productId: String?
  /// Catégorie ; `nil` ou inconnue : celle de `other`, sinon la dernière.
  public var categoryId: String?
  /// Libellé normalisé (#7), comparé octet par octet en UTF-8 dans le repli.
  public var normalizedName: String

  public init(id: String, productId: String?, categoryId: String?, normalizedName: String) {
    self.id = id
    self.productId = productId
    self.categoryId = categoryId
    self.normalizedName = normalizedName
  }

  enum CodingKeys: String, CodingKey {
    case id
    case productId = "product_id"
    case categoryId = "category_id"
    case normalizedName = "normalized_name"
  }
}

/// Point de départ du trajet, résolu par l'app : le dernier article coché ayant un produit,
/// sinon l'entrée du magasin.
public enum SortStart: Sendable, Equatable, Codable {
  case entry
  case product(String)

  enum CodingKeys: String, CodingKey {
    case entry
    case productId = "product_id"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Comme `"entry" in start` dans la référence : la présence de la clé suffit.
    if container.contains(.entry) {
      self = .entry
    } else {
      self = .product(try container.decode(String.self, forKey: .productId))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .entry: try container.encode(true, forKey: .entry)
    case .product(let productId): try container.encode(productId, forKey: .productId)
    }
  }
}

/// Entrée complète du tri : une valeur `Sendable`, prête à passer hors du main actor.
public struct SortInput: Sendable, Equatable, Codable {
  public var params: SortParams
  public var categories: [SortCategory]
  /// `nil` : magasin inconnu, d'où le repli par catégorie.
  public var snapshot: SortSnapshot?
  public var items: [SortItem]
  public var start: SortStart
  /// Ordre affiché juste avant (hystérésis) ; `nil` et `[]` sont équivalents.
  public var previousOrder: [String]?

  public init(
    params: SortParams = .default, categories: [SortCategory], snapshot: SortSnapshot?,
    items: [SortItem], start: SortStart, previousOrder: [String]?
  ) {
    self.params = params
    self.categories = categories
    self.snapshot = snapshot
    self.items = items
    self.start = start
    self.previousOrder = previousOrder
  }

  enum CodingKeys: String, CodingKey {
    case params, categories, snapshot, items, start
    case previousOrder = "previous_order"
  }
}

/// Résultat du tri.
public struct SortOutput: Sendable, Equatable, Codable {
  /// Mode utilisé : graphe appris ou repli par catégorie.
  public enum Mode: String, Sendable, Equatable, Codable {
    case learned
    case fallback
  }

  public var mode: Mode
  /// Identifiants des articles, dans l'ordre du trajet.
  public var order: [String]
  /// Coût entier du chemin retenu, départ compris ; `nil` en repli.
  public var cost: Int64?

  public init(mode: Mode, order: [String], cost: Int64?) {
    self.mode = mode
    self.order = order
    self.cost = cost
  }
}

/// Entrée refusée par la validation : on refuse plutôt que de deviner.
public enum SortError: Error, Sendable, Equatable {
  /// Identifiant hors de `[0-9a-z-]+` ; `field` dit où il a été trouvé.
  case invalidId(field: String, value: String)
  case duplicateCategory(String)
  case duplicateItem(String)
  /// Poids hors de `0...2^53-1` ; `context` désigne l'arête ou l'entrée fautive.
  case invalidWeight(context: String, weightQ: Int64)
}
