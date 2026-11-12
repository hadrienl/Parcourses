package fr.parcourses.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Garde-fou (#54) : aucun journal HTTP dans l'app. Un `install(Logging)` de Ktor ou un intercepteur de journal
 * OkHttp écrirait dans logcat les coordonnées envoyées à `nearby_stores`, les jetons et le contenu des listes.
 * Pour journaliser en local, le faire hors du dépôt.
 */
class NoHttpLoggingTest {
    /** Racine du projet Android : les tests unitaires tournent depuis le dossier du module. */
    private val root =
        generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "settings.gradle.kts").isFile }

    private val forbidden =
        listOf(
            "io.ktor.client.plugins.logging",
            "install(Logging)",
            "HttpLoggingInterceptor",
            "okhttp3.logging",
        )

    @Test
    fun noSourceInstallsAnHttpLogger() {
        val sources =
            root
                .walkTopDown()
                .onEnter { it.name != "build" && it.name != ".gradle" }
                .filter { it.isFile && it.extension == "kt" && "${File.separator}src${File.separator}main" in it.path }
                .toList()
        assertTrue("aucune source lue depuis $root", sources.size > 10)
        val offenders =
            sources.filter { file -> forbidden.any { it in file.readText() } }.map { it.relativeTo(root).path }
        assertEquals(emptyList<String>(), offenders)
    }

    @Test
    fun noHttpLoggingLibraryIsDeclared() {
        val catalog = File(root, "gradle/libs.versions.toml").readText()
        assertTrue(catalog.isNotBlank())
        assertTrue("ktor-client-logging déclaré", "ktor-client-logging" !in catalog)
        assertTrue("logging-interceptor déclaré", "logging-interceptor" !in catalog)
    }
}
