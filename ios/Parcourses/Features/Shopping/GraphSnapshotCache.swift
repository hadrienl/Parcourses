import Foundation
import SortEngine

/// Instantané décodé : ce que le tri consomme et ce que l'écran affiche.
nonisolated struct LoadedSnapshot: Sendable, Equatable {
  let version: Int64
  let params: SortParams
  let snapshot: SortSnapshot
}

/// Contenu de `store_graph_snapshot` (#11 §7). Tout autre champ du JSON est ignoré.
private nonisolated struct GraphSnapshotPayload: Decodable {
  static let supportedFormat = 1

  let formatVersion: Int
  let snapshotVersion: Int64
  let paramsVersion: Int64
  let params: SortParams
  let confidenceQ: Int64
  let entries: [SnapshotEntry]
  let edges: [SnapshotEdge]

  enum CodingKeys: String, CodingKey {
    case formatVersion = "format_version"
    case snapshotVersion = "snapshot_version"
    case paramsVersion = "params_version"
    case params
    case confidenceQ = "confidence_q"
    case entries, edges
  }

  /// `nil` si le format est inconnu : on trie alors sans graphe plutôt que de deviner.
  static func decode(_ data: Data) -> GraphSnapshotPayload? {
    guard let payload = try? JSONDecoder().decode(Self.self, from: data), payload.formatVersion == supportedFormat
    else { return nil }
    return payload
  }

  var loaded: LoadedSnapshot {
    LoadedSnapshot(
      version: snapshotVersion, params: params,
      snapshot: SortSnapshot(confidenceQ: confidenceQ, entries: entries, edges: edges))
  }
}

/// Cache local de l'instantané d'un magasin. Sans réseau ni session, le cache suffit.
struct GraphSnapshotCache {
  let graphs: any GraphRepository
  let gateway: (any RemoteGateway)?
  var now: () -> Date = { .now }

  func cached(storeId: UUID) -> LoadedSnapshot? {
    guard let row = try? graphs.snapshot(storeId: storeId) else { return nil }
    return GraphSnapshotPayload.decode(row.payload)?.loaded
  }

  /// Interroge le serveur et enregistre une nouvelle version. `nil` si rien de neuf.
  /// Un instantané illisible ne donne pas sa version : il sera redemandé en entier.
  func refresh(storeId: UUID) async throws -> LoadedSnapshot? {
    guard let gateway else { return nil }
    let known = cached(storeId: storeId)?.version
    guard case .payload(let data) = try await gateway.graphSnapshot(storeId: storeId, knownVersion: known),
      let payload = GraphSnapshotPayload.decode(data)
    else { return nil }
    try graphs.saveSnapshot(
      storeId: storeId, snapshotVersion: payload.snapshotVersion, paramsVersion: payload.paramsVersion,
      confidenceQ: payload.confidenceQ, payload: data, at: now())
    return payload.loaded
  }
}
