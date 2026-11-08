package fr.parcourses.core.database

import androidx.room3.testing.MigrationTestHelper
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Chaque version du schéma est commitée dans `schemas/`. Ce test relit ces fichiers : une migration ajoutée
 * plus tard (`runMigrationsAndValidate(N, listOf(MIGRATION_N_1_N))`) se vérifie ici, sur les données de la version
 * précédente.
 */
@RunWith(AndroidJUnit4::class)
class MigrationTest {
    // Fichier unique par instance de test (JUnit crée une instance par test) ; l'assistant le supprime en fin de test.
    private val databaseFile = File.createTempFile("migration", ".db")

    @get:Rule
    val helper =
        MigrationTestHelper(
            InstrumentationRegistry.getInstrumentation(),
            databaseFile,
            AndroidSQLiteDriver(),
            ParcoursesDatabase::class,
            { ParcoursesDatabase_Impl() },
            emptyList(),
        )

    @Test
    fun exportedSchemaOfTheCurrentVersionIsCommitted() {
        val file = File("schemas/${ParcoursesDatabase::class.qualifiedName}/${ParcoursesDatabase.VERSION}.json")
        assertTrue("Schéma exporté absent : ${file.absolutePath}", file.isFile)
    }

    @Test
    fun version1CreatedFromTheExportedSchemaMatchesWhatRoomExpects() =
        runBlocking {
            helper.createDatabase(1).close()
            // Aucune migration à jouer : l'ouverture valide les tables, colonnes et index de la version 1.
            helper.runMigrationsAndValidate(ParcoursesDatabase.VERSION, emptyList()).close()
        }
}
