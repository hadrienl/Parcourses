package fr.parcourses.app

import androidx.navigation3.runtime.NavKey

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
