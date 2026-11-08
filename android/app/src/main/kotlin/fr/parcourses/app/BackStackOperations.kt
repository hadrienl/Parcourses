package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.feature.shopping.ShoppingSummary
import fr.parcourses.feature.storepicker.StorePickerOutcome

/** Reprise de compte : les écrans ouverts suivent les nouveaux identifiants de leur liste. */
internal fun MutableList<NavKey>.applyRemap(remap: IdentifierRemap) {
    forEachIndexed { index, key ->
        when (key) {
            is Route.ListDetail -> this[index] = key.copy(listId = remap[key.listId])
            is Route.StorePicker -> this[index] = key.copy(listId = remap[key.listId])
            is Route.Shopping -> this[index] = key.copy(listId = remap[key.listId])
            is Route.ShoppingSummary -> this[index] = key.remapped(remap)
            else -> Unit
        }
    }
}

/** Le résumé suit sa liste et sa visite ; l'écran (son slot) ne change pas. */
private fun Route.ShoppingSummary.remapped(remap: IdentifierRemap) =
    copy(listId = remap[listId], summary = summary.copy(visitId = summary.visitId?.let(remap::get)))

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

/**
 * Ouvre le mode courses pour [choice], une seule fois. Le choix n'est pris que si l'écran Liste de [StoreChoice.listId]
 * est encore au sommet : un choix périmé (retour déjà fait, autre liste) ne rouvre aucune visite. Renvoie `true`
 * si le mode courses a été ouvert.
 */
internal fun MutableList<NavKey>.openShopping(choice: StoreChoice): Boolean {
    val top = lastOrNull() as? Route.ListDetail
    if (top == null || top.listId != choice.listId) return false
    val storeId = (choice.outcome as? StorePickerOutcome.Store)?.id
    add(Route.Shopping(choice.listId, storeId))
    return true
}

/**
 * Reprise au lancement d'une visite ouverte : la pile ne contient que l'écran Listes. Sinon (pile restaurée,
 * l'utilisateur a déjà navigué) elle est laissée telle quelle.
 */
internal fun MutableList<NavKey>.resumeShopping(visit: ResumableVisit): Boolean {
    if (size != 1 || first() != Route.Lists) return false
    add(Route.ListDetail(visit.listId))
    add(Route.Shopping(visit.listId, visit.storeId))
    return true
}

/**
 * Fin des courses : le mode courses identifié par [slot] cède sa place au résumé, s'il est encore au sommet. Le
 * résumé reçoit un slot neuf : l'entrée du mode courses quitte la pile et son `ShoppingViewModel` est détruit.
 * Renvoie `true` si la pile a changé.
 */
internal fun MutableList<NavKey>.finishShopping(
    slot: String,
    summary: ShoppingSummary,
): Boolean {
    val top = lastOrNull() as? Route.Shopping
    if (top == null || top.slot != slot) return false
    this[lastIndex] = Route.ShoppingSummary(top.listId, summary)
    return true
}

/**
 * Retour de l'écran identifié par [slot] (sélecteur de magasin ou mode courses). Ne dépile que si cet écran est
 * encore au sommet : un double appui sur Retour (ou un retour système après le bouton) ne fait pas sauter l'écran
 * du dessous.
 */
internal fun MutableList<NavKey>.popIfTop(slot: String): Boolean {
    val top = lastOrNull()
    val topSlot =
        when (top) {
            is Route.StorePicker -> top.slot
            is Route.Shopping -> top.slot
            is Route.ShoppingSummary -> top.slot
            is Route.ListDetail -> top.slot
            else -> null
        }
    if (topSlot != slot) return false
    removeAt(lastIndex)
    return true
}
