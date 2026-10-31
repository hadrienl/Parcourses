package fr.parcourses.app

import org.junit.Assert.assertEquals
import org.junit.Test

// Vérifie que l'identifiant de l'app reste stable (il ne doit jamais changer après publication).
class AppConfigTest {
    @Test
    fun applicationIdIsStable() {
        assertEquals("fr.parcourses.app", BuildConfig.APPLICATION_ID)
    }
}
