// Rayon effectif d'un article selon le magasin (#28). Calculé sur l'appareil, avant le tri :
// `sort.ts` reçoit le résultat comme `category_id` et ne connaît pas la notion de bio.

export const BIO_CATEGORY = "bio";

/** Sans magasin choisi (mode liste), passer `storeOrganicAisle = false`. */
export function effectiveCategory(
  categoryId: string,
  organic: boolean,
  storeOrganicAisle: boolean,
): string {
  return organic && storeOrganicAisle ? BIO_CATEGORY : categoryId;
}
