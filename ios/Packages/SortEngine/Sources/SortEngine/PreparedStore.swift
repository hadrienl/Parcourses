// Magasin préparé pour le tri (#30) : le travail qui ne dépend que de l'instantané est fait une
// fois par visite au lieu d'une fois par tri.

import Synchronization

/// Instantané validé une fois, graphe construit au premier tri en mode appris, distances depuis
/// chaque source calculées au premier besoin puis réutilisées par les tris suivants de la visite
/// (recalcul après chaque coche).
///
/// Lié à une valeur immuable (instantané, paramètres) : un nouvel instantané demande un nouveau
/// `PreparedStore`. ``sortItems(_:prepared:)`` ne s'en sert que si ``matches(_:)`` est vrai ; le
/// résultat reste donc celui de ``sortItems(_:)``, seule la durée change.
///
/// Mémoire : une ligne de `8 × (produits + 1)` octets par source utilisée, soit au plus une
/// centaine de lignes par visite.
public final class PreparedStore: Sendable {
  /// Instantané préparé.
  public let snapshot: SortSnapshot
  /// Paramètres préparés : le coût des arêtes en dépend.
  public let params: SortParams
  private let state = Mutex(State())

  private struct State {
    var graph: StoreGraph?
    /// Distances par nœud source du graphe (l'entrée comprise).
    var rows: [Int: [Int64]] = [:]
  }

  /// - Throws: ``SortError`` si l'instantané est invalide, comme ``sortItems(_:)``.
  public convenience init(snapshot: SortSnapshot, params: SortParams) throws(SortError) {
    try validateSnapshot(snapshot)
    self.init(validated: snapshot, params: params)
  }

  /// Magasin d'un seul tri : l'instantané vient d'être validé avec le reste de l'entrée.
  init(validated snapshot: SortSnapshot, params: SortParams) {
    self.snapshot = snapshot
    self.params = params
  }

  /// Vrai si `input` porte exactement cet instantané et ces paramètres.
  public func matches(_ input: SortInput) -> Bool {
    input.params == params && input.snapshot == snapshot
  }

  /// Nombre de sources déjà calculées (tests).
  var cachedSources: Int { state.withLock { $0.rows.count } }

  /// Graphe construit à la première utilisation.
  var graph: StoreGraph {
    state.withLock { state in
      if let graph = state.graph { return graph }
      let graph = StoreGraph(snapshot, params)
      state.graph = graph
      return graph
    }
  }

  /// Distances depuis le nœud `source` du graphe, calculées une seule fois.
  func distances(from source: Int) -> [Int64] {
    let graph = self.graph
    return state.withLock { state in
      if let row = state.rows[source] { return row }
      let row = graph.distances(from: source)
      state.rows[source] = row
      return row
    }
  }
}
