package fr.parcourses.core.database

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.database.entity.CheckEntity
import fr.parcourses.core.database.entity.ProductEntity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CategorySeedTest : DatabaseTest() {
    private val dairy = SeedCategory("dairy", 70, "Crèmerie")
    private val bio = SeedCategory("bio", 85, "Bio")
    private val other = SeedCategory("other", 999, "Autres")

    private fun seed(
        version: Int,
        vararg categories: SeedCategory,
        renamed: Map<String, String> = emptyMap(),
    ) = CategorySeed(version, categories.toList(), renamed)

    @Test
    fun bundledReferentialFillsAnEmptyDatabaseInRankOrder() =
        runBlocking {
            val bundled = CategorySeed.bundled()
            assertTrue(db.categories().seedIfNeeded(bundled))

            val stored = db.categories().getAll()
            assertEquals(21, stored.size)
            assertEquals(bundled.categories.map { it.id }, stored.map { it.id })
            assertEquals(listOf("produce", "bakery"), stored.take(2).map { it.id })
            assertEquals("other", stored.last().id)
            assertEquals(bundled.version, db.categories().seedState()?.version)
            assertTrue(stored.all { it.slug == it.id && it.remoteId == null })
        }

    @Test
    fun seedIsNotReplayedUnlessVersionIncreases() =
        runBlocking {
            assertTrue(db.categories().seedIfNeeded(seed(2, dairy, other)))
            assertFalse(db.categories().seedIfNeeded(seed(2, other)))
            assertFalse(db.categories().seedIfNeeded(seed(1, other)))
            assertEquals(listOf("dairy", "other"), db.categories().getAll().map { it.id })
        }

    @Test
    fun newVersionUpsertsRemovesAbsentOnesAndKeepsRemoteIds() =
        runBlocking {
            db.categories().seedIfNeeded(seed(1, dairy, other))
            db.categories().setRemoteId("dairy", 7)

            db.categories().seedIfNeeded(seed(2, dairy.copy(label = "Frais"), bio, other))
            val stored = db.categories().getAll().associateBy { it.id }
            assertEquals(listOf("dairy", "bio", "other").sorted(), stored.keys.sorted())
            assertEquals("Frais", stored.getValue("dairy").label)
            assertEquals(7, stored.getValue("dairy").remoteId)
            assertEquals(listOf("dairy", "bio", "other"), db.categories().getAll().map { it.id })

            db.categories().seedIfNeeded(seed(3, other))
            assertEquals(listOf("other"), db.categories().getAll().map { it.id })
        }

    @Test
    fun removedCategoryFallsBackToOtherAndRenamedOneFollowsItsSuccessor() =
        runBlocking {
            db.categories().seedIfNeeded(seed(1, dairy, bio, other))
            db.lists().upsert(list("l"))
            db.items().upsertAll(listOf(item("a", "l", 0, "dairy"), item("b", "l", 1, "bio")))
            db.products().upsertAll(listOf(ProductEntity("p", "Lait", "lait", "dairy")))
            db.checks().upsert(CheckEntity("c", "v", "a", null, "dairy", at(1)))

            val milk = SeedCategory("milk", 70, "Lait")
            db.categories().seedIfNeeded(seed(2, milk, other, renamed = mapOf("dairy" to "milk")))

            assertEquals("milk", db.items().get("a")?.categoryId)
            assertEquals("other", db.items().get("b")?.categoryId)
            assertEquals("milk", db.products().get("p")?.categoryId)
            assertEquals("milk", db.checks().get("c")?.categoryId)
        }
}
