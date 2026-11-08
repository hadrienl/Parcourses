package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Reprise d'une visite restée ouverte, **une fois par processus** et seulement au lancement à froid de l'activité.
 * Une recréation (rotation, thème, taille du texte, pliage) recompose `ParcoursesNavHost` et relance ses effets :
 * sans ce verrou, l'app réempilerait d'elle-même la liste puis le mode courses par-dessus l'écran Listes.
 */
class LaunchResume {
    private val claimed = AtomicBoolean(false)

    /** Vrai une seule fois, et seulement si [coldStart] : l'activité démarre sans état sauvegardé. */
    fun claim(coldStart: Boolean): Boolean = coldStart && claimed.compareAndSet(false, true)
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
    return find()?.let { resumeShopping(it) } ?: false
}
