package fr.parcourses.core.location

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Looper
import androidx.core.location.LocationManagerCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.emptyFlow
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicInteger
import com.google.android.gms.location.LocationResult as GmsLocationResult

/**
 * Source de points. Le flux se termine quand la source n'a plus rien à donner, ou à l'annulation du collecteur.
 * Une [SecurityException] signale que l'autorisation a été retirée.
 */
fun interface FixSource {
    fun updates(precise: Boolean): Flow<LocationFix>
}

internal fun Location.toFix(): LocationFix =
    LocationFix(
        latitude = latitude,
        longitude = longitude,
        horizontalAccuracyM = if (hasAccuracy()) accuracy.toDouble() else -1.0,
        timestampMillis = time,
    )

/** Google Play Services (Fused) : mise à jour toutes les secondes jusqu'à ce que la sélection s'arrête. */
class FusedFixSource(
    private val context: Context,
    private val now: () -> Long = System::currentTimeMillis,
) : FixSource {
    // Les appelants vérifient l'autorisation avant ; une révocation en cours de route lève SecurityException.
    @SuppressLint("MissingPermission")
    override fun updates(precise: Boolean): Flow<LocationFix> =
        callbackFlow {
            val client = LocationServices.getFusedLocationProviderClient(context)
            val priority = if (precise) Priority.PRIORITY_HIGH_ACCURACY else Priority.PRIORITY_BALANCED_POWER_ACCURACY
            val request =
                LocationRequest
                    .Builder(priority, UPDATE_INTERVAL_MS)
                    .setMinUpdateIntervalMillis(UPDATE_INTERVAL_MS / 2)
                    .build()
            val callback =
                object : LocationCallback() {
                    override fun onLocationResult(result: GmsLocationResult) {
                        result.locations.forEach { trySend(it.toFix()) }
                    }
                }
            // Un dernier point très récent évite d'attendre le premier relevé ; la sélection l'écarte s'il est périmé.
            client.lastLocation.addOnSuccessListener { last ->
                if (last != null && now() - last.time <= FixSelection.LAST_KNOWN_MAX_AGE_MS) trySend(last.toFix())
            }
            client.requestLocationUpdates(request, callback, Looper.getMainLooper()).addOnFailureListener {
                close(it)
            }
            awaitClose { client.removeLocationUpdates(callback) }
        }

    private companion object {
        const val UPDATE_INTERVAL_MS = 1_000L
    }
}

/**
 * Repli sans Google Play Services : `LocationManager.getCurrentLocation` (API 30+). Avant, le flux est vide et
 * l'écran propose la recherche par nom.
 */
class PlatformFixSource(
    private val context: Context,
    private val executor: Executor = Executor { it.run() },
) : FixSource {
    @SuppressLint("MissingPermission")
    override fun updates(precise: Boolean): Flow<LocationFix> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyFlow()
        val manager = context.getSystemService(LocationManager::class.java) ?: return emptyFlow()
        val providers = providers(manager, precise)
        if (providers.isEmpty()) return emptyFlow()
        return callbackFlow {
            val signal = CancellationSignal()
            val pending = AtomicInteger(providers.size)
            providers.forEach { provider ->
                LocationManagerCompat.getCurrentLocation(manager, provider, signal, executor) { location ->
                    if (location != null) trySend(location.toFix())
                    if (pending.decrementAndGet() == 0) close()
                }
            }
            awaitClose { signal.cancel() }
        }
    }

    // Précis : GPS puis réseau ; approximatif : réseau (ou fusionné dès Android 12), jamais le GPS.
    private fun providers(
        manager: LocationManager,
        precise: Boolean,
    ): List<String> {
        val candidates =
            buildList {
                if (precise) add(LocationManager.GPS_PROVIDER)
                add(LocationManager.NETWORK_PROVIDER)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(LocationManager.FUSED_PROVIDER)
            }
        return candidates.filter { manager.isProviderEnabled(it) }
    }
}

/** Vrai si Google Play Services est utilisable sur cet appareil. */
fun isGooglePlayServicesAvailable(context: Context): Boolean =
    GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
