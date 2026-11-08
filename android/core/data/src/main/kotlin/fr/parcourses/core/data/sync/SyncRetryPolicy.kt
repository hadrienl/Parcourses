package fr.parcourses.core.data.sync

import fr.parcourses.core.network.RemoteError
import kotlin.math.pow
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/** Plafonds et délais de reprise (#9 §5.3). Mêmes valeurs que `SyncRetryPolicy` d'iOS. */
object SyncRetryPolicy {
    /** `23503` : le parent peut encore arriver, mais pas indéfiniment. */
    const val MAX_DEPENDENCY_ATTEMPTS = 8

    /** Catégorie inconnue : le serveur peut être en retard d'une migration. Jamais abandonnée. */
    val unknownCategoryDelay: Duration = 1.hours
    val minimumDelay: Duration = 2.seconds
    val maximumDelay: Duration = 5.minutes

    /** Erreur serveur sur une même ligne : au-delà, elle ne retient plus le reste de la file. */
    val serverFailureGrace: Duration = 4.hours

    /** Délai avant de réessayer une ligne mise de côté. Reste `PENDING`. */
    val parkedRetryDelay: Duration = 6.hours

    /** Article refusé (`42501`) car sa liste n'est pas encore reçue : il l'attend, sans consommer d'essai. */
    val listWaitDelay: Duration = 30.seconds

    /** Catalogue : une fois par jour (#9 §5.4). */
    val catalogInterval: Duration = 24.hours

    /** Descente après un envoi : l'envoi d'une coche ne doit pas relire les listes à chaque fois. */
    val pullAfterSendInterval: Duration = 60.seconds

    /** Une descente en échec ne se retente qu'une fois par minute, sans gêner l'envoi. */
    val pullRetryInterval: Duration = 60.seconds

    /** Entrées par appel à `resolve_products`, sa limite côté serveur. */
    const val MAX_RESOLUTION_BATCH = 100

    /** Résolution des produits en échec : l'envoi continue, la résolution attend. */
    val resolutionRetryInterval: Duration = 60.seconds

    /** RPC absente du serveur (`PGRST202`) : l'app peut sortir avant la migration, qui arrivera vite. */
    val resolutionUnavailableInterval: Duration = 5.minutes

    /** Autre refus définitif (requête refusée) : inutile d'insister à chaque passe. */
    val resolutionRejectedInterval: Duration = 1.hours

    /** Délai de la résolution après une erreur. */
    fun resolutionDelay(error: Throwable): Duration =
        when {
            error !is RemoteError -> {
                resolutionRetryInterval
            }

            error is RemoteError.Rejected && error.code == RemoteError.FUNCTION_NOT_FOUND_CODE -> {
                resolutionUnavailableInterval
            }

            error.isRetryable -> {
                resolutionRetryInterval
            }

            else -> {
                resolutionRejectedInterval
            }
        }

    /** Délai exponentiel de 2 s à 5 min, dispersé par [jitter] (0,8 à 1,2). */
    fun delay(
        attempt: Int,
        jitter: Double,
    ): Duration {
        val exponent = minOf(maxOf(attempt, 1) - 1, MAX_EXPONENT)
        return minOf(maximumDelay, minimumDelay * (2.0.pow(exponent) * jitter))
    }

    private const val MAX_EXPONENT = 16
}
