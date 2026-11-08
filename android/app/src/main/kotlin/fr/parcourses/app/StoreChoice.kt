package fr.parcourses.app

import fr.parcourses.feature.storepicker.StorePickerOutcome

/**
 * Magasin choisi (ou « sans magasin ») pour faire les courses de [listId]. Le mode courses (A8) le reprend pour
 * ouvrir la visite ; la position n'y figure pas.
 */
data class StoreChoice(
    val listId: String,
    val outcome: StorePickerOutcome,
)
