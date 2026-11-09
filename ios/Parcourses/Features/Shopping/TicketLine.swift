import Foundation

/// Une ligne du ticket du mode courses : le nœud d'un rayon, ou un article. Toutes les lignes sont sur le même fil.
enum TicketLine: Identifiable, Equatable {
  case aisle(ShoppingSection)
  case item(ShoppingRow)

  /// Identité stable entre deux tris : l'article garde la sienne, le rayon la sienne (préfixée, distincte d'un UUID).
  var id: String {
    switch self {
    case .aisle(let section): "aisle:\(section.id)"
    case .item(let row): row.id.uuidString
    }
  }

  /// Lignes dans l'ordre affiché : chaque rayon, puis ses articles.
  static func lines(of sections: [ShoppingSection]) -> [TicketLine] {
    sections.flatMap { [.aisle($0)] + $0.rows.map(TicketLine.item) }
  }

  /// Rayons qui sont remontés après un tri : parmi les rayons présents avant et après, ceux qui passent devant un
  /// rayon qui les précédait. Un rayon vidé (tout coché) ou nouveau ne fait rien remonter.
  static func raisedSections(previous: [String], current: [String]) -> Set<String> {
    let common = Set(previous).intersection(current)
    let before = previous.filter(common.contains)
    let after = current.filter(common.contains)
    let rank = Dictionary(uniqueKeysWithValues: before.enumerated().map { ($1, $0) })
    var raised: Set<String> = []
    for (index, id) in after.enumerated() {
      // Remonté : un rayon qui le précédait est maintenant derrière lui.
      let overtaken = after[(index + 1)...].contains { (rank[$0] ?? 0) < (rank[id] ?? 0) }
      if overtaken { raised.insert(id) }
    }
    return raised
  }
}
