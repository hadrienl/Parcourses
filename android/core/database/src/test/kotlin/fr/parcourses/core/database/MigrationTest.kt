package fr.parcourses.core.database

import androidx.room3.testing.MigrationTestHelper
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.sqlite.execSQL
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
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
    fun version1CreatedFromTheExportedSchemaMatchesWhatRoomExpects() =
        runBlocking {
            // Le schéma exporté de la version 1 s'ouvre et se valide tel quel.
            helper.createDatabase(1).close()
        }

    @Test
    fun exportedSchemaOfTheCurrentVersionIsCommitted() {
        val file = File("schemas/${ParcoursesDatabase::class.qualifiedName}/${ParcoursesDatabase.VERSION}.json")
        assertTrue("Schéma exporté absent : ${file.absolutePath}", file.isFile)
    }

    /**
     * #87 (lot 87.5) : la version 2 ajoute `lists.ownerId`, `list_items.isOnServer` / `updatedBy` et
     * `outbox.changedFields`. Un article `SYNCED` est déjà sur le serveur ; une entrée de file d'avant garde
     * `changedFields` nul (ancien envoi). Les données de la version 1 restent intactes.
     */
    @Test
    fun version1MigratesToVersion2AndKeepsItsData() =
        runBlocking {
            helper.createDatabase(1).use { v1 ->
                v1.execSQL(
                    "INSERT INTO lists (id, name, createdAt, updatedAt, deletedAt, syncState) " +
                        "VALUES ('l1', 'Courses', 0, 0, NULL, 'SYNCED')",
                )
                for ((id, state) in listOf("sent" to "SYNCED", "edited" to "PENDING")) {
                    v1.execSQL(
                        "INSERT INTO list_items (id, listId, label, normalizedName, quantity, productId, categoryId, " +
                            "checkedAt, notFoundAt, position, updatedAt, syncState) " +
                            "VALUES ('$id', 'l1', 'lait', 'lait', NULL, NULL, 'dairy', NULL, NULL, 0, 0, '$state')",
                    )
                }
                v1.execSQL(
                    "INSERT INTO outbox (id, sequence, kindRaw, entityId, payload, createdAt, attempts, " +
                        "nextAttemptAt, lastError, syncState, serverFailingSince) " +
                        "VALUES ('e1', 1, 'upsertItem', 'edited', x'7B7D', 0, 0, 0, NULL, 'PENDING', NULL)",
                )
            }

            helper.runMigrationsAndValidate(2, DatabaseMigrations.ALL.toList()).use { v2 ->
                v2.prepare("SELECT ownerId FROM lists WHERE id = 'l1'").use {
                    assertTrue(it.step())
                    assertTrue(it.isNull(0))
                }
                v2.prepare("SELECT id, isOnServer, updatedBy FROM list_items ORDER BY id").use {
                    val rows = mutableMapOf<String, Long>()
                    while (it.step()) {
                        assertTrue(it.isNull(2))
                        rows[it.getText(0)] = it.getLong(1)
                    }
                    assertEquals(mapOf("edited" to 0L, "sent" to 1L), rows)
                }
                v2.prepare("SELECT changedFields, entityId FROM outbox").use {
                    assertTrue(it.step())
                    assertTrue(it.isNull(0))
                    assertEquals("edited", it.getText(1))
                }
            }
        }
}
