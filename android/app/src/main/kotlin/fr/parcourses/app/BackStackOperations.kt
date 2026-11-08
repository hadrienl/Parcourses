package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.feature.storepicker.StorePickerOutcome

/** Reprise de compte : les écrans ouverts suivent les nouveaux identifiants de leur liste. */
internal fun MutableList<NavKey>.applyRemap(remap: IdentifierRemap) {
    forEachIndexed { index, key ->
        when (key) {
            is Route.ListDetail -> this[index] = key.copy(listId = remap[key.listId])
            is Route.StorePicker -> this[index] = key.copy(listId = remap[key.listId])
            else -> Unit
        }
    }
}

/** Ouvre le choix du magasin, une seule fois même sur un double appui. */
internal fun MutableList<NavKey>.openStorePicker(listId: String) {
    if (lastOrNull() !is Route.StorePicker) add(Route.StorePicker(listId))
}

/**
 * Fin du choix du magasin. Ne fait rien (et ne rend aucun choix) si l'écran identifié par [slot] n'est plus au
 * sommet : retour déjà fait, ou second événement. Sinon le dépile et rend le choix avec l'identifiant de liste
 * *actuel* de la pile, donc celui d'après une reprise de compte.
 */
internal fun MutableList<NavKey>.finishStorePicker(
    slot: String,
    outcome: StorePickerOutcome,
): StoreChoice? {
    val top = lastOrNull() as? Route.StorePicker
    if (top == null || top.slot != slot) return null
    removeAt(lastIndex)
    return StoreChoice(top.listId, outcome)
}
