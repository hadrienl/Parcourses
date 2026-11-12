package fr.parcourses.feature.storepicker

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.provider.Settings
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/** Réglages ouverts depuis le choix du magasin : un appareil sans la page voulue ne fait pas planter l'écran (#54). */
@RunWith(AndroidJUnit4::class)
class SettingsIntentsTest {
    /** Appareil sans aucune page de réglages. */
    private class NoSettings(
        base: Context,
    ) : ContextWrapper(base) {
        val attempts = mutableListOf<String?>()

        override fun startActivity(intent: Intent) {
            attempts += intent.action
            throw ActivityNotFoundException(intent.action)
        }
    }

    private val context = NoSettings(ApplicationProvider.getApplicationContext())

    @Test
    fun theAppSettingsPageMissingIsNotACrash() {
        context.openAppSettings()
        assertEquals(listOf(Settings.ACTION_APPLICATION_DETAILS_SETTINGS), context.attempts)
    }

    @Test
    fun theLocationSettingsPageMissingIsNotACrash() {
        context.openLocationSettings()
        assertEquals(listOf(Settings.ACTION_LOCATION_SOURCE_SETTINGS), context.attempts)
    }
}
