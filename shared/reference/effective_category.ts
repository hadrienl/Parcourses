// Rayon effectif d'un article selon le magasin (#28). Calculé sur l'appareil, avant le tri :
// `sort.ts` reçoit le résultat comme `category_id` et ne connaît pas la notion de bio.

export const BIO_CATEGORY = "bio";
/** Un surgelé bio reste au rayon surgelés, même si le magasin a un rayon bio. */
export const FROZEN_CATEGORY = "frozen";

/** Sans magasin choisi (mode liste), passer `storeOrganicAisle = false`. */
export function effectiveCategory(
  categoryId: string,
  organic: boolean,
  storeOrganicAisle: boolean,
): string {
  return organic && storeOrganicAisle && categoryId !== FROZEN_CATEGORY ? BIO_CATEGORY : categoryId;
}
