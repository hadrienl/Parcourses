package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import java.util.concurrent.atomic.AtomicReference

/**
 * Reprise d'une visite restée ouverte, **une fois par processus** et seulement au lancement à froid de l'activité.
 * Une recréation (rotation, thème, taille du texte, pliage) recompose `ParcoursesNavHost` et relance ses effets :
 * sans ce verrou, l'app réempilerait d'elle-même la liste puis le mode courses par-dessus l'écran Listes.
 *
 * Une recherche interrompue avant sa fin (recréation pendant la lecture de la visite, dans les toutes premières
 * millisecondes) ne compte pas : la composition suivante la reprend, même sans être un lancement à froid (#54, M2).
 */
class LaunchResume {
    private enum class State { Idle, Running, Interrupted, Done }

    private val state = AtomicReference(State.Idle)

    /**
     * Vrai une seule fois : au lancement à froid ([coldStart], l'activité démarre sans état sauvegardé), ou à la
     * composition qui suit une recherche interrompue.
     */
    fun claim(coldStart: Boolean): Boolean =
        (coldStart && state.compareAndSet(State.Idle, State.Running)) ||
            state.compareAndSet(State.Interrupted, State.Running)

    /** La recherche est allée au bout : plus aucune reprise dans ce processus. */
    fun finish() = state.set(State.Done)

    /** La recherche n'est pas allée au bout (composition quittée) : la suivante pourra la refaire. */
    fun interrupt() {
        state.compareAndSet(State.Running, State.Interrupted)
    }
}

/**
 * Reprise au lancement : ne lit la visite ([find]) que si [gate] l'autorise, puis l'empile sur une pile neuve.
 * Renvoie `true` si le mode courses a été rouvert.
 */
internal suspend fun MutableList<NavKey>.resumeOnLaunch(
    gate: LaunchResume,
    coldStart: Boolean,
    find: suspend () -> ResumableVisit?,
): Boolean {
    if (!gate.claim(coldStart)) return false
    var found = false
    val visit =
        try {
            find().also { found = true }
        } finally {
            if (found) gate.finish() else gate.interrupt()
        }
    return visit?.let { resumeShopping(it) } ?: false
}
