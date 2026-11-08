package fr.parcourses.core.location

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.takeWhile

/** Choix du point d'une requête ponctuelle, séparé des API système pour être testé. Mêmes règles qu'iOS (9.8). */
object FixSelection {
    /** Seuil de précision qui met fin à la requête. */
    const val TARGET_ACCURACY_M = 100.0

    /** Échéance de la requête. */
    const val TIMEOUT_MS = 8_000L

    /**
     * Un point en cache peut désigner le mauvais magasin. Il arrive aussi seul quand l'utilisateur ne bouge pas :
     * il est donc gardé, marqué périmé.
     */
    const val MAX_AGE_MS = 30_000L

    /** Dernier point connu admis comme premier point (hors précision temps réel). */
    const val LAST_KNOWN_MAX_AGE_MS = 120_000L

    sealed interface Event {
        data class Point(
            val fix: LocationFix,
        ) : Event

        data object Denied : Event

        data object Deadline : Event
    }

    /**
     * [isApproximate] : le seuil de précision n'est jamais atteint et le premier point suffit, quel que soit son âge.
     */
    suspend fun select(
        events: Flow<Event>,
        isApproximate: Boolean,
        now: () -> Long = System::currentTimeMillis,
    ): LocationResult {
        val selector = Selector(isApproximate, now)
        events.takeWhile { event -> selector.accept(event) }.collect {}
        return selector.result()
    }

    private class Selector(
        private val isApproximate: Boolean,
        private val now: () -> Long,
    ) {
        private var best: LocationFix? = null
        private var decided: LocationResult? = null

        /** Faux quand la décision est prise : la collecte s'arrête. */
        fun accept(event: Event): Boolean {
            when (event) {
                Event.Deadline -> decided = result()
                Event.Denied -> decided = LocationResult.Denied
                is Event.Point -> onPoint(event.fix)
            }
            return decided == null
        }

        fun result(): LocationResult = decided ?: best?.let(LocationResult::Fix) ?: LocationResult.Unavailable

        private fun onPoint(point: LocationFix) {
            // Précision inconnue : inutilisable pour choisir.
            if (point.horizontalAccuracyM < 0) return
            if (isApproximate) {
                decided = LocationResult.Fix(point)
                return
            }
            val fix = point.copy(isStale = now() - point.timestampMillis > MAX_AGE_MS)
            if (!fix.isStale && fix.horizontalAccuracyM <= TARGET_ACCURACY_M) {
                decided = LocationResult.Fix(fix)
            } else if (best?.let { isBetter(fix, it) } != false) {
                best = fix
            }
        }
    }

    /** Un point récent passe devant un point périmé, même plus précis. */
    private fun isBetter(
        fix: LocationFix,
        than: LocationFix,
    ): Boolean =
        if (fix.isStale != than.isStale) {
            than.isStale
        } else {
            fix.horizontalAccuracyM < than.horizontalAccuracyM
        }
}
