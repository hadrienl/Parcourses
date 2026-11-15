package fr.parcourses.app

import androidx.navigation3.runtime.NavKey

// Pile de navigation du partage (#87, lot 87.6).

/** « Partager » ou « Membres » d'une liste, une seule fois même sur un double appui (#87). */
internal fun MutableList<NavKey>.openShareList(listId: String) {
    if (lastOrNull() !is Route.ShareList) add(Route.ShareList(listId))
}

/**
 * La personne a quitté [listId], ou la liste ne lui est plus accessible : ses écrans (liste, partage, choix du
 * magasin) quittent la pile, qui revient à « Mes listes » sans rien d'autre (#87).
 */
internal fun MutableList<NavKey>.closeList(listId: String) {
    removeAll { key ->
        when (key) {
            is Route.ListDetail -> key.listId == listId
            is Route.ShareList -> key.listId == listId
            is Route.StorePicker -> key.listId == listId
            else -> false
        }
    }
    if (isEmpty()) add(Route.Lists)
}

/**
 * Une liste à ouvrir après une invitation acceptée : au-dessus de « Mes listes », les écrans d'invitation retirés.
 */
internal fun MutableList<NavKey>.openAcceptedList(listId: String) {
    removeAll { it == Route.Invitation || it == Route.Invitations }
    if (none { it is Route.ListDetail && it.listId == listId }) add(Route.ListDetail(listId))
}

/** Ouvre l'invitation d'un lien, une seule fois ; une connexion en cours la fera ouvrir à sa fin. */
internal fun MutableList<NavKey>.openInvitation() {
    if (lastOrNull() != Route.Invitation) add(Route.Invitation)
}
