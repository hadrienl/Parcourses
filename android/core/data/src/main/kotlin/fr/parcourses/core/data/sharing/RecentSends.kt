package fr.parcourses.core.data.sharing

import java.util.concurrent.ConcurrentHashMap
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

/**
 * Envois d'articles récents, liste par liste (#87 §6.2) : le serveur prévient aussi l'auteur d'une écriture. Un signal
 * `items` reçu pendant un envoi vers la même liste, ou moins de [echoWindow] après, est l'écho de ses propres écritures
 * et ne demande pas de descente. Un vrai changement d'un autre membre dans cette fenêtre attend la descente suivante.
 */
class RecentSends(
    private val now: () -> Instant = { Clock.System.now() },
    private val echoWindow: Duration = ECHO_WINDOW,
) {
    private val last = ConcurrentHashMap<String, Instant>()

    /** Un envoi vers [listId] commence ou vient de réussir. */
    fun record(listId: String) {
        last[listId] = now()
    }

    fun isEcho(listId: String): Boolean = last[listId]?.let { now() - it < echoWindow } == true

    companion object {
        val ECHO_WINDOW: Duration = 2.seconds
    }
}
