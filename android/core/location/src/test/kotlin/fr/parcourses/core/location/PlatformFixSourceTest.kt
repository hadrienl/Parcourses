package fr.parcourses.core.location

import android.content.Context
import android.location.Location
import android.location.LocationManager
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class PlatformFixSourceTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val manager = context.getSystemService(LocationManager::class.java)

    private fun location(
        provider: String,
        accuracy: Float,
    ) = Location(provider).apply {
        latitude = 45.0
        longitude = 5.0
        this.accuracy = accuracy
        time = 1234
    }

    @Test
    fun aDisabledProviderGivesNothing() =
        runTest {
            shadowOf(manager).setProviderEnabled(LocationManager.GPS_PROVIDER, false)
            shadowOf(manager).setProviderEnabled(LocationManager.NETWORK_PROVIDER, false)
            assertEquals(emptyList<LocationFix>(), PlatformFixSource(context).updates(precise = true).toList())
        }

    @Test
    fun anEnabledProviderGivesItsPoint() =
        runTest {
            shadowOf(manager).setProviderEnabled(LocationManager.NETWORK_PROVIDER, true)
            shadowOf(manager).setProviderEnabled(LocationManager.GPS_PROVIDER, false)
            shadowOf(manager).setLastKnownLocation(LocationManager.NETWORK_PROVIDER, location("network", 80f))
            val fixes = PlatformFixSource(context).updates(precise = false).toList()
            assertEquals(1, fixes.size)
            assertEquals(80.0, fixes.single().horizontalAccuracyM, 0.0)
            assertEquals(1234L, fixes.single().timestampMillis)
        }

    @Test
    @Config(sdk = [28])
    fun beforeAndroid11TheSourceStaysEmpty() =
        runTest {
            shadowOf(manager).setProviderEnabled(LocationManager.NETWORK_PROVIDER, true)
            assertEquals(emptyList<LocationFix>(), PlatformFixSource(context).updates(precise = true).toList())
        }
}
