package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.feature.shopping.ShoppingSummary
import fr.parcourses.feature.storepicker.StorePickerOutcome

/** Données supprimées (#68) : la pile repart sur l'écran Listes seul. */
internal fun MutableList<NavKey>.resetToLists() {
    if (size == 1 && first() == Route.Lists) return
    clear()
    add(Route.Lists)
}

/**
 * Suppression des données en cours (#68) : le mode courses, son choix de magasin et son résumé quittent la pile, sans
 * fermer la visite (elle va être effacée). Le reste, À propos compris, ne bouge pas.
 */
internal fun MutableList<NavKey>.closeShopping() {
    removeAll { it is Route.Shopping || it is Route.StorePicker || it is Route.ShoppingSummary }
    if (isEmpty()) add(Route.Lists)
}

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

/**
 * Ouvre la liste [listId] depuis l'écran Listes, seulement si celui-ci est au sommet. Un double appui n'empile pas
 * deux fois l'écran, et une liste créée après qu'on a quitté l'écran Listes (« À propos », autre liste ouverte
 * pendant l'écriture) ne s'empile pas par-dessus (#54). Renvoie `true` si la liste a été ouverte.
 */
internal fun MutableList<NavKey>.openListFromLists(listId: String): Boolean {
    if (lastOrNull() != Route.Lists) return false
    add(Route.ListDetail(listId))
    return true
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
 * Lien de la Live Update vers la visite ouverte [visit] : la pile devient `[Lists, Shopping]` (#10 §8.1). Si ce mode
 * courses est déjà au sommet (même liste, même magasin), rien ne change : ni second écran ni état perdu. Renvoie
 * `true` si la pile a changé.
 */
internal fun MutableList<NavKey>.openLinkedShopping(visit: ResumableVisit): Boolean {
    val top = lastOrNull()
    if (top is Route.Shopping && top.listId == visit.listId && top.storeId == visit.storeId) return false
    if (firstOrNull() != Route.Lists) {
        clear()
        add(Route.Lists)
    }
    while (size > 1) removeAt(lastIndex)
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
