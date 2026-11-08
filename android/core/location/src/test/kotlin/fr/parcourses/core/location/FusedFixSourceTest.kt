package fr.parcourses.core.location

import android.location.Location
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import java.lang.reflect.Proxy
import com.google.android.gms.location.LocationResult as GmsLocationResult

/** Client Fused simulé : enregistre les demandes de mises à jour et leur retrait. */
private class FakeFusedClient {
    var requested: LocationRequest? = null
    var callback: LocationCallback? = null
    val removed = mutableListOf<LocationCallback>()

    val client: FusedLocationProviderClient =
        Proxy.newProxyInstance(
            FusedLocationProviderClient::class.java.classLoader,
            arrayOf(FusedLocationProviderClient::class.java),
        ) { _, method, args ->
            when (method.name) {
                "requestLocationUpdates" -> {
                    requested = args[0] as LocationRequest
                    callback = args[1] as LocationCallback
                    Tasks.forResult<Void>(null)
                }

                "removeLocationUpdates" -> {
                    removed += args[0] as LocationCallback
                    Tasks.forResult<Void>(null)
                }

                "getLastLocation" -> {
                    Tasks.forResult<Location>(null)
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
        val location =
            Location("fused").apply {
                latitude = 48.0
                longitude = 2.0
                this.accuracy = accuracy
                time = at
            }
        callback!!.onLocationResult(GmsLocationResult.create(listOf(location)))
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
