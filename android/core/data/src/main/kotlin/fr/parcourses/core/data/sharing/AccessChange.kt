package fr.parcourses.core.data.sharing

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Accès d'une liste partagée changé par un autre membre (#87 §1.5), à montrer à la personne. */
sealed interface AccessChange {
    val listId: String

    /** La liste n'est plus accessible (retrait, liste supprimée) : elle a quitté l'appareil. */
    data class Removed(
        override val listId: String,
        val listName: String,
    ) : AccessChange

    /** Passé en lecture seule. [lostChanges] : modifications en attente jetées (0 : aucune). */
    data class Downgraded(
        override val listId: String,
        val ownerName: String?,
        val lostChanges: Int,
    ) : AccessChange

    /** Passé de la lecture seule à la modification. */
    data class Upgraded(
        override val listId: String,
        val ownerName: String?,
    ) : AccessChange
}

/** Messages d'accès en attente d'être vus, un au plus par liste. En mémoire : ils ne survivent pas au processus. */
class SharingNotices {
    private val pending = MutableStateFlow<List<AccessChange>>(emptyList())

    val notices: StateFlow<List<AccessChange>> = pending.asStateFlow()

    fun post(change: AccessChange) = pending.update { old -> old.filterNot { it.listId == change.listId } + change }

    fun acknowledge(change: AccessChange) = pending.update { old -> old - change }

    /** Listes vues à l'émission précédente de [listsPresent] ; `null` avant la première. */
    private var known: Set<String>? = null

    /**
     * Listes présentes sur l'appareil, à chaque changement (un seul appelant). Une liste retirée qui **revient**
     * (réinvitée, puis acceptée) n'a plus de message « n'est plus partagée ». Seule une arrivée compte : une émission
     * en retard qui montre encore la liste juste retirée n'efface rien.
     */
    @Synchronized
    fun listsPresent(ids: Set<String>) {
        val back = known?.let { ids - it }.orEmpty()
        known = ids
        if (back.isNotEmpty()) {
            pending.update { old ->
                old.filterNot { it is AccessChange.Removed && it.listId in back }
            }
        }
    }

    /** Purge des données (déconnexion, suppression) : plus rien à montrer. */
    fun clear() = pending.update { emptyList() }
}
