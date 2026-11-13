import SwiftUI

/// Habillage d'un rayon : icône au trait (`design/icons/categories/`) et famille de couleur. Table commune avec
/// Android (A11) ; `other` n'a pas de famille et prend la couleur du texte secondaire.
enum AisleStyle {
  enum Family: String, CaseIterable {
    case fresh, dairy, grocery, hygiene, bio
  }

  /// Rayons de `shared/categories/` → famille.
  static let families: [String: Family] = [
    "produce": .fresh, "bakery": .fresh, "butcher": .fresh, "deli": .fresh, "seafood": .fresh,
    "cheese": .dairy, "dairy": .dairy, "frozen": .dairy, "beverages": .dairy,
    "savory-grocery": .grocery, "world-food": .grocery, "breakfast": .grocery, "sweet-grocery": .grocery,
    "snacks": .grocery, "alcohol": .grocery,
    "baby": .hygiene, "hygiene": .hygiene, "household": .hygiene, "pets": .hygiene,
    "bio": .bio,
  ]

  /// Rayons qui ont une icône : un rayon inconnu prend celle de `other`.
  static let iconIds: Set<String> = Set(families.keys).union(["other"])

  static func color(_ aisleId: String) -> Color {
    switch families[aisleId] {
    case .fresh: Palette.Aisle.fresh
    case .dairy: Palette.Aisle.dairy
    case .grocery: Palette.Aisle.grocery
    case .hygiene: Palette.Aisle.hygiene
    case .bio: Palette.Aisle.bio
    case nil: Palette.inkMuted
    }
  }

  static func iconName(_ aisleId: String) -> String {
    "cat." + (iconIds.contains(aisleId) ? aisleId : "other")
  }
}
