package fr.parcourses.core.location

import android.location.Location
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import java.lang.reflect.Proxy
import com.google.android.gms.location.LocationResult as GmsLocationResult

/** Client Fused simulé : enregistre les demandes de mises à jour et leur retrait. */
private class FakeFusedClient {
    var requested: LocationRequest? = null
    var callback: LocationCallback? = null
    val removed = mutableListOf<LocationCallback>()

    /** Échec asynchrone de la demande de mises à jour (Google Play Services en panne). */
    var updatesFailure: Exception? = null

    /** Dernier point connu rendu par `getLastLocation`. */
    var last: Location? = null

    val client: FusedLocationProviderClient =
        Proxy.newProxyInstance(
            FusedLocationProviderClient::class.java.classLoader,
            arrayOf(FusedLocationProviderClient::class.java),
        ) { _, method, args ->
            when (method.name) {
                "requestLocationUpdates" -> {
                    requested = args[0] as LocationRequest
                    callback = args[1] as LocationCallback
                    // Le type de la tâche est effacé à l'exécution : seul compte son issue.
                    val failure = updatesFailure
                    if (failure != null) Tasks.forException<Any?>(failure) else Tasks.forResult<Any?>(null)
                }

                "removeLocationUpdates" -> {
                    removed += args[0] as LocationCallback
                    Tasks.forResult<Void>(null)
                }

                "getLastLocation" -> {
                    Tasks.forResult(last)
                }

                else -> {
                    if (Task::class.java.isAssignableFrom(method.returnType)) Tasks.forResult<Void>(null) else null
                }
            }
        } as FusedLocationProviderClient

    fun deliver(
        accuracy: Float,
        at: Long = 0,
    ) {
        callback!!.onLocationResult(GmsLocationResult.create(listOf(location(accuracy, at))))
    }

    companion object {
        fun location(
            accuracy: Float,
            at: Long,
        ) = Location("fused").apply {
            latitude = 48.0
            longitude = 2.0
            this.accuracy = accuracy
            time = at
        }
    }
}

@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalCoroutinesApi::class)
class FusedFixSourceTest {
    @Test
    fun cancellingTheCollectionStopsTheUpdates() =
        runTest {
            val fake = FakeFusedClient()
            val job = backgroundScope.launch { FusedFixSource({ fake.client }, now = { 0 }).updates(true).collect {} }
            runCurrent()
            assertNotNull(fake.callback)
            assertEquals(emptyList<LocationCallback>(), fake.removed)
            job.cancel()
            runCurrent()
            assertEquals(listOf(fake.callback), fake.removed)
        }

    /** Les rappels des `Task` de Google Play Services passent par le fil principal, en pause sous Robolectric. */
    private fun TestScope.settle() {
        runCurrent()
        shadowOf(Looper.getMainLooper()).idle()
        runCurrent()
    }

    @Test
    fun anAsynchronousFailureOfTheUpdatesFallsBackToThePlatform() =
        runTest {
            // #54 : la demande est acceptée, puis échoue plus tard (et non en levant tout de suite).
            val fake = FakeFusedClient().apply { updatesFailure = IllegalStateException("services indisponibles") }
            val point = LocationFix(48.5, 2.5, 25.0, timestampMillis = 0)
            val provider =
                SystemLocationProvider(
                    authorizationSource = { LocationAuthorization.Precise },
                    primary = FusedFixSource({ fake.client }, now = { 0 }),
                    fallback = { flowOf(point) },
                    now = { 0 },
                )
            var result: LocationResult? = null
            backgroundScope.launch { result = provider.currentFix() }
            settle()
            assertEquals(LocationResult.Fix(point), result)
        }

    @Test
    fun aStaleLastKnownPointIsNotOfferedButARecentOneIs() =
        runTest {
            val clock = FixSelection.LAST_KNOWN_MAX_AGE_MS + 1_000
            val stale = FakeFusedClient().apply { last = FakeFusedClient.location(accuracy = 10f, at = 0) }
            val seen = mutableListOf<LocationFix>()
            val job =
                backgroundScope.launch {
                    FusedFixSource({ stale.client }, now = { clock }).updates(true).collect { seen += it }
                }
            settle()
            assertTrue(seen.isEmpty())
            job.cancel()

            val recent = FakeFusedClient().apply { last = FakeFusedClient.location(accuracy = 10f, at = clock - 1_000) }
            backgroundScope.launch {
                FusedFixSource({ recent.client }, now = { clock }).updates(true).collect { seen += it }
            }
            settle()
            assertEquals(listOf(clock - 1_000), seen.map { it.timestampMillis })
        }

    @Test
    fun theSelectionEndingStopsTheUpdates() =
        runTest {
            val fake = FakeFusedClient()
            val provider =
                SystemLocationProvider(
                    authorizationSource = { LocationAuthorization.Precise },
                    primary = FusedFixSource({ fake.client }, now = { 0 }),
                    fallback = { error("pas appelée") },
                    now = { 0 },
                )
            var result: LocationResult? = null
            backgroundScope.launch { result = provider.currentFix() }
            runCurrent()
            fake.deliver(accuracy = 30f)
            runCurrent()
            assertEquals(30.0, (result as LocationResult.Fix).fix.horizontalAccuracyM, 0.0)
            assertSame(fake.callback, fake.removed.single())
        }

    @Test
    fun theDeadlineStopsTheUpdatesToo() =
        runTest {
            val fake = FakeFusedClient()
            val provider =
                SystemLocationProvider(
                    authorizationSource = { LocationAuthorization.Precise },
                    primary = FusedFixSource({ fake.client }, now = { 0 }),
                    fallback = { error("pas appelée") },
                    now = { 0 },
                )
            var result: LocationResult? = null
            backgroundScope.launch { result = provider.currentFix() }
            runCurrent()
            fake.deliver(accuracy = 500f)
            testScheduler.advanceTimeBy(FixSelection.TIMEOUT_MS + 1)
            runCurrent()
            assertEquals(500.0, (result as LocationResult.Fix).fix.horizontalAccuracyM, 0.0)
            assertEquals(1, fake.removed.size)
        }

    @Test
    fun priorityFollowsThePrecisionGranted() =
        runTest {
            val precise = FakeFusedClient()
            val approximate = FakeFusedClient()
            val a = backgroundScope.launch { FusedFixSource({ precise.client }, { 0 }).updates(true).collect {} }
            val b = backgroundScope.launch { FusedFixSource({ approximate.client }, { 0 }).updates(false).collect {} }
            runCurrent()
            assertEquals(com.google.android.gms.location.Priority.PRIORITY_HIGH_ACCURACY, precise.requested?.priority)
            assertEquals(
                com.google.android.gms.location.Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                approximate.requested?.priority,
            )
            a.cancel()
            b.cancel()
        }
}
