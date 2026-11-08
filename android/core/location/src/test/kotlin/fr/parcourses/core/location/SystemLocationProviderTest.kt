package fr.parcourses.core.location

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SystemLocationProviderTest {
    private val point = LocationFix(48.0, 2.0, 30.0, timestampMillis = 0)

    private fun provider(
        authorization: LocationAuthorization = LocationAuthorization.Precise,
        primary: FixSource? = null,
        fallback: FixSource = FixSource { emptyFlow() },
    ) = SystemLocationProvider(
        authorizationSource = { authorization },
        primary = primary,
        fallback = fallback,
        now = { 0 },
        timeoutMs = FixSelection.TIMEOUT_MS,
    )

    @Test
    fun withoutAuthorizationNothingIsRequested() =
        runTest {
            var asked = false
            val source = FixSource { flow { asked = true } }
            val result = provider(LocationAuthorization.Denied, primary = source).currentFix()
            assertEquals(LocationResult.Denied, result)
            assertEquals(false, asked)
        }

    @Test
    fun theSourceIsAskedForPrecisionOnlyWhenPrecise() =
        runTest {
            val asked = mutableListOf<Boolean>()
            val source =
                FixSource { precise ->
                    asked += precise
                    flowOf(point)
                }
            provider(LocationAuthorization.Precise, primary = source).currentFix()
            provider(LocationAuthorization.Approximate, primary = source).currentFix()
            assertEquals(listOf(true, false), asked)
        }

    @Test
    fun theFirstSourceWinsWhenItAnswers() =
        runTest {
            val result = provider(primary = { flowOf(point) }, fallback = { error("pas appelée") }).currentFix()
            assertEquals(LocationResult.Fix(point), result)
        }

    @Test
    fun aFailingPrimaryFallsBackToThePlatform() =
        runTest {
            val broken: Flow<LocationFix> = flow { throw IllegalStateException("Play Services indisponible") }
            val result = provider(primary = { broken }, fallback = { flowOf(point) }).currentFix()
            assertEquals(LocationResult.Fix(point), result)
        }

    @Test
    fun withoutPlayServicesThePlatformIsUsed() =
        runTest {
            assertEquals(LocationResult.Fix(point), provider(primary = null, fallback = { flowOf(point) }).currentFix())
        }

    @Test
    fun aSilentSourceWaitsForTheDeadlineThenIsUnavailable() =
        runTest {
            val silent = FixSource { flow { kotlinx.coroutines.awaitCancellation() } }
            val result = provider(primary = silent, fallback = { error("pas appelée") }).currentFix()
            assertEquals(LocationResult.Unavailable, result)
            assertEquals(FixSelection.TIMEOUT_MS, currentTime)
        }

    @Test
    fun anExhaustedSourceDoesNotWaitForTheDeadline() =
        runTest {
            assertEquals(LocationResult.Unavailable, provider(primary = { emptyFlow() }).currentFix())
            assertEquals(0L, currentTime)
        }

    @Test
    fun aSecurityExceptionMeansTheAuthorizationWasRevoked() =
        runTest {
            val revoked: Flow<LocationFix> = flow { throw SecurityException("retirée") }
            assertEquals(LocationResult.Denied, provider(primary = { revoked }).currentFix())
        }
}
