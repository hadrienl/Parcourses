package fr.parcourses.core.location

import fr.parcourses.core.location.FixSelection.Event
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FixSelectionTest {
    private val now = 1_000_000L

    private fun fix(
        accuracy: Double,
        ageMs: Long = 0,
        latitude: Double = 48.0,
    ) = LocationFix(latitude, 2.0, accuracy, now - ageMs)

    private suspend fun select(
        vararg events: Event,
        approximate: Boolean = false,
    ) = FixSelection.select(flowOf(*events), approximate) { now }

    @Test
    fun aRecentAndAccuratePointEndsTheRequest() =
        runTest {
            val good = fix(accuracy = 20.0)
            // Les événements suivants ne sont jamais lus.
            assertEquals(LocationResult.Fix(good), select(Event.Point(good), Event.Denied))
        }

    @Test
    fun anInaccuratePointWaitsForABetterOne() =
        runTest {
            val rough = fix(accuracy = 400.0)
            val better = fix(accuracy = 60.0, latitude = 49.0)
            val result = select(Event.Point(rough), Event.Point(better), Event.Deadline)
            assertEquals(LocationResult.Fix(better), result)
        }

    @Test
    fun atTheDeadlineTheBestPointIsKept() =
        runTest {
            val first = fix(accuracy = 300.0)
            val second = fix(accuracy = 150.0, latitude = 49.0)
            val third = fix(accuracy = 250.0, latitude = 50.0)
            val result = select(Event.Point(first), Event.Point(second), Event.Point(third), Event.Deadline)
            assertEquals(LocationResult.Fix(second), result)
        }

    @Test
    fun aStalePointIsKeptButMarkedAndNeverBeatsARecentOne() =
        runTest {
            val stale = fix(accuracy = 10.0, ageMs = 60_000)
            val recent = fix(accuracy = 500.0, latitude = 49.0)
            val onlyStale = select(Event.Point(stale), Event.Deadline) as LocationResult.Fix
            assertTrue(onlyStale.fix.isStale)
            // Même plus précis, un point périmé ne passe pas devant un point récent.
            val mixed = select(Event.Point(stale), Event.Point(recent), Event.Deadline) as LocationResult.Fix
            assertFalse(mixed.fix.isStale)
            assertEquals(49.0, mixed.fix.latitude, 0.0)
        }

    @Test
    fun anUnknownAccuracyIsIgnored() =
        runTest {
            assertEquals(LocationResult.Unavailable, select(Event.Point(fix(accuracy = -1.0)), Event.Deadline))
        }

    @Test
    fun theFirstPointIsEnoughWhenApproximateWhateverItsAge() =
        runTest {
            val old = fix(accuracy = 3_000.0, ageMs = 10 * 60_000)
            val result = select(Event.Point(old), approximate = true) as LocationResult.Fix
            assertEquals(old, result.fix)
        }

    @Test
    fun aRevokedPermissionIsReported() =
        runTest {
            assertEquals(LocationResult.Denied, select(Event.Point(fix(accuracy = 500.0)), Event.Denied))
        }

    @Test
    fun noPointAtTheDeadlineMeansUnavailable() =
        runTest {
            assertEquals(LocationResult.Unavailable, select(Event.Deadline))
            assertEquals(LocationResult.Unavailable, select())
        }

    @Test
    fun aFixNeverShowsItsCoordinates() {
        assertFalse(fix(accuracy = 5.0, latitude = 48.8566).toString().contains("48.85"))
    }
}
