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

  /// Rayons qui sont remontés après un tri : ceux dont un article passe devant un article d'un autre rayon qu'il
  /// suivait. Le calcul porte sur les articles, pas sur les identités de rayons : une reprise de rayon renumérotée
  /// (`produce#1` devenu `produce`) ou un article ajouté en route ne fait rien remonter. Les articles absents de
  /// l'ordre précédent sont ignorés. Même règle qu'Android (A11).
  static func raisedSections(previous: [UUID], current: [ShoppingSection]) -> Set<String> {
    let before = Dictionary(previous.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let items = current.flatMap { section in section.rows.map { (section: section, row: $0) } }
    var raised: Set<String> = []
    for (index, item) in items.enumerated() {
      guard !raised.contains(item.section.id), let was = before[item.row.id] else { continue }
      // Un article d'un autre rayon, autrefois devant lui, est maintenant derrière.
      let overtakes = items[(index + 1)...].contains { other in
        other.row.aisleId != item.row.aisleId && (before[other.row.id].map { $0 < was } ?? false)
      }
      if overtakes { raised.insert(item.section.id) }
    }
    return raised
  }
}
