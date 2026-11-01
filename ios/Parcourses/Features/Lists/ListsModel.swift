import Foundation
import Observation

/// Une liste telle qu'affichée : une valeur, jamais l'objet SwiftData, pour survivre à sa suppression.
struct ListSummary: Identifiable, Equatable {
  let id: UUID
  let name: String
  let remaining: Int
  let total: Int

  var subtitle: String {
    if total == 0 { return "Aucun article" }
    if remaining == 0 { return "Tout est coché" }
    return remaining == 1 ? "1 article restant" : "\(remaining) articles restants"
  }
}

/// Modèle de l'écran Listes.
@Observable
final class ListsModel {
  private(set) var lists: [ListSummary] = []
  var errorMessage: String?

  private let repository: any ListRepository
  private let now: () -> Date

  init(lists: any ListRepository, now: @escaping () -> Date = { .now }) {
    repository = lists
    self.now = now
  }

  func load() {
    perform {
      lists = try repository.lists().map(summary(of:))
    }
  }

  /// Crée une liste et renvoie son identifiant, `nil` si le nom est vide ou en cas d'erreur.
  func create(name: String) -> UUID? {
    guard let name = Self.cleaned(name) else { return nil }
    var id: UUID?
    perform { id = try repository.createList(name: name, at: now()).id }
    load()
    return id
  }

  func rename(id: UUID, name: String) {
    guard let name = Self.cleaned(name) else { return }
    perform { try repository.renameList(id: id, name: name, at: now()) }
    load()
  }

  func delete(id: UUID) {
    perform { try repository.deleteList(id: id, at: now()) }
    load()
  }

  /// Vrai si le nom saisi peut être enregistré.
  static func isValid(name: String) -> Bool {
    cleaned(name) != nil
  }

  private func summary(of list: ShoppingList) throws -> ListSummary {
    let items = try repository.items(listId: list.id)
    return ListSummary(
      id: list.id, name: list.name, remaining: items.count { $0.checkedAt == nil }, total: items.count)
  }

  private static func cleaned(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func perform(_ work: () throws -> Void) {
    do {
      try work()
    } catch {
      errorMessage = "L'opération a échoué : \(error.localizedDescription)"
    }
  }
}
