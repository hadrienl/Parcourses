/// Identifiant de la catégorie du rayon bio (#28). Elle ne reçoit aucun article par mot-clé.
public let organicCategoryId = "bio"

/// Un surgelé bio reste au rayon surgelés, même si le magasin a un rayon bio.
public let frozenCategoryId = "frozen"

/// Rayon effectif d'un article selon le magasin (#28), identique à
/// `shared/reference/effective_category.ts`. À calculer avant l'appel au tri.
///
/// Sans magasin choisi (mode liste), passer `storeOrganicAisle: false`.
public func effectiveCategory(categoryId: String, organic: Bool, storeOrganicAisle: Bool) -> String {
  organic && storeOrganicAisle && categoryId != frozenCategoryId ? organicCategoryId : categoryId
}
