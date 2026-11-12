package fr.parcourses.core.location

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Position ponctuelle. Google Play Services d'abord (source principale), repli sur le gestionnaire du système
 * ([fallback]) sans lui ou s'il échoue. Les points restent en mémoire.
 *
 * La source principale n'est choisie qu'à la première lecture, sur [io] : savoir si Google Play Services est là
 * interroge le gestionnaire de paquets, ce qui n'a rien à faire sur le fil principal à l'ouverture de l'écran (#54).
 */
class SystemLocationProvider internal constructor(
    private val authorizationSource: () -> LocationAuthorization,
    private val resolvePrimary: () -> FixSource?,
    private val fallback: FixSource,
    private val now: () -> Long,
    private val timeoutMs: Long,
    private val io: CoroutineDispatcher,
) : LocationProvider {
    constructor(context: Context) : this(
        authorizationSource = { authorizationOf(context) },
        resolvePrimary = { if (isGooglePlayServicesAvailable(context)) FusedFixSource(context) else null },
        fallback = PlatformFixSource(context),
        now = System::currentTimeMillis,
        timeoutMs = FixSelection.TIMEOUT_MS,
        io = Dispatchers.IO,
    )

    /** Sources déjà construites (tests). */
    constructor(
        authorizationSource: () -> LocationAuthorization,
        primary: FixSource?,
        fallback: FixSource,
        now: () -> Long = System::currentTimeMillis,
        timeoutMs: Long = FixSelection.TIMEOUT_MS,
    ) : this(authorizationSource, { primary }, fallback, now, timeoutMs, Dispatchers.Unconfined)

    private val primaryLock = Mutex()
    private var primary: FixSource? = null
    private var isPrimaryResolved = false

    private suspend fun primary(): FixSource? =
        primaryLock.withLock {
            if (!isPrimaryResolved) {
                primary = withContext(io) { resolvePrimary() }
                isPrimaryResolved = true
            }
            primary
        }

    override val authorization: LocationAuthorization
        get() = authorizationSource()

    override suspend fun currentFix(): LocationResult {
        val level = authorization
        if (level == LocationAuthorization.Denied) return LocationResult.Denied
        val precise = level == LocationAuthorization.Precise
        val sources = listOfNotNull(primary(), fallback)
        var result: LocationResult = LocationResult.Unavailable
        for (source in sources) {
            var failed = false
            val events = merge(points(source, precise) { failed = true }, deadline())
            result = FixSelection.select(events, isApproximate = !precise, now = now)
            // Seul un échec de la source (pas un simple manque de point) donne sa chance à la suivante.
            if (result != LocationResult.Unavailable || !failed) break
        }
        return result
    }

    private fun points(
        source: FixSource,
        precise: Boolean,
        onFailure: () -> Unit,
    ): Flow<FixSelection.Event> =
        source
            .updates(precise)
            .map<LocationFix, FixSelection.Event> { FixSelection.Event.Point(it) }
            .catch { error ->
                if (error is CancellationException) throw error
                // SecurityException : l'autorisation vient d'être retirée. Autre échec : la source ne répond pas.
                if (error is SecurityException) {
                    emit(FixSelection.Event.Denied)
                } else {
                    onFailure()
                }
            }
            // Une source épuisée (ou en panne) n'a plus rien à donner : inutile d'attendre l'échéance.
            .onCompletion { cause -> if (cause == null) emit(FixSelection.Event.Deadline) }

    private fun deadline(): Flow<FixSelection.Event> =
        flow {
            delay(timeoutMs)
            emit(FixSelection.Event.Deadline)
        }

    companion object {
        fun authorizationOf(context: Context): LocationAuthorization =
            when {
                granted(context, Manifest.permission.ACCESS_FINE_LOCATION) -> LocationAuthorization.Precise
                granted(context, Manifest.permission.ACCESS_COARSE_LOCATION) -> LocationAuthorization.Approximate
                else -> LocationAuthorization.Denied
            }

        private fun granted(
            context: Context,
            permission: String,
        ) = ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }
}
