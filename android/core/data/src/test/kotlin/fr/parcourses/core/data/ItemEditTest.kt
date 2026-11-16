package fr.parcourses.core.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.outbox.ItemFields
import fr.parcourses.core.data.outbox.OutboxCoding
import fr.parcourses.core.data.repository.RepositoryException
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.dto.ListItemUpsert
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.seconds

// Modification d'un article (#110) : `updateItem` du dépôt et `applyEdit`, le chemin du panneau de l'article.
@RunWith(AndroidJUnit4::class)
class ItemEditTest : DataTest() {
    private var wakeUps = 0
    private val repository by lazy { RoomListRepository(db, onEnqueue = { wakeUps++ }) }
    private val analyzer = EntryAnalyzer()

    /**
     * Un article déjà parti au serveur, modifié en dernier par un autre membre, avec un produit : la file est vide,
     * le changement suivant ne part qu'en mise à jour des seuls champs modifiés.
     */
    private suspend fun sentItem(
        label: String = "lait",
        quantity: String? = "1",
    ): ListItemEntity {
        val list = repository.createList("Courses", now)
        val normalized = classifier.classify(label)
        val item =
            repository
                .addItem(list.id, label, normalized.normalized, quantity, PRODUCT, normalized.categoryId, now)
                .copy(syncState = SyncState.SYNCED, isOnServer = true, updatedBy = OTHER)
        db.items().upsert(item)
        db.outbox().all().forEach { db.outbox().delete(it.id) }
        wakeUps = 0
        advance(1.seconds)
        return item
    }

    private suspend fun queued() = db.outbox().pending().single()

    private suspend fun sentFields() = ItemFields.decode(queued().changedFields)

    @Test
    fun aNewQuantityAloneIsSent() =
        runBlocking {
            val item = sentItem()
            repository.updateItem(item.id, item.label, item.normalizedName, item.categoryId, "3", now)

            assertEquals(listOf(ItemFields.QUANTITY), sentFields())
            assertEquals(OutboxKind.UpsertItem, queued().kind())
            assertEquals("3", OutboxCoding.decode(ListItemUpsert.serializer(), queued().payload).quantity)
            val stored = requireNotNull(db.items().get(item.id))
            assertEquals("3", stored.quantity)
            assertEquals(PRODUCT, stored.productId)
            // Comme une coche : la dernière modification devient la mienne, à l'heure de l'écriture.
            assertEquals(now, stored.updatedAt)
            assertNull(stored.updatedBy)
            assertEquals(SyncState.PENDING, stored.syncState)
            assertEquals(1, wakeUps)
        }

    @Test
    fun aClearedQuantityIsSentAsNull() =
        runBlocking {
            val item = sentItem()
            repository.updateItem(item.id, item.label, item.normalizedName, item.categoryId, null, now)
            assertEquals(listOf(ItemFields.QUANTITY), sentFields())
            assertNull(db.items().get(item.id)?.quantity)
        }

    @Test
    fun nothingChangedWritesNothing() =
        runBlocking {
            val item = sentItem()
            repository.updateItem(item.id, item.label, item.normalizedName, item.categoryId, item.quantity, now)
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(item, db.items().get(item.id))
            assertEquals(0, wakeUps)
        }

    @Test
    fun aNewLabelIsReclassifiedAndForgetsItsProduct() =
        runBlocking {
            val item = sentItem()
            repository.applyEdit(ItemEdit("pommes", "1"), item.id, analyzer, now)

            assertEquals(listOf(ItemFields.LABEL, ItemFields.PRODUCT_ID), sentFields())
            val stored = requireNotNull(db.items().get(item.id))
            assertEquals("pommes", stored.label)
            assertEquals(classifier.classify("pommes").normalized, stored.normalizedName)
            assertEquals("produce", stored.categoryId)
            // Le produit correspondait à l'ancien libellé : la résolution de produit repassera.
            assertNull(stored.productId)
            val row = OutboxCoding.decode(ListItemUpsert.serializer(), queued().payload)
            assertEquals("pommes", row.label)
            assertNull(row.productId)
        }

    @Test
    fun aLabelOfTheSameFormKeepsItsProduct() =
        runBlocking {
            val item = sentItem(label = "lait")
            repository.applyEdit(ItemEdit("Lait", "2"), item.id, analyzer, now)

            // Même forme normalisée : le produit reste, seuls le libellé et la quantité partent (triés).
            assertEquals(listOf(ItemFields.LABEL, ItemFields.QUANTITY), sentFields())
            val stored = requireNotNull(db.items().get(item.id))
            assertEquals("Lait", stored.label)
            assertEquals(item.normalizedName, stored.normalizedName)
            assertEquals(PRODUCT, stored.productId)
            assertEquals("2", stored.quantity)
        }

    @Test
    fun aNewLabelWithoutProductSendsTheLabelAlone() =
        runBlocking {
            val item = sentItem().copy(productId = null)
            db.items().upsert(item)
            repository.applyEdit(ItemEdit("pommes", "1"), item.id, analyzer, now)
            assertEquals(listOf(ItemFields.LABEL), sentFields())
        }

    @Test
    fun aQuantityTypedInTheLabelStaysInTheLabel() =
        runBlocking {
            val item = sentItem()
            repository.applyEdit(requireNotNull(ItemEdit.of("  2 lait ", "")), item.id, analyzer, now)
            val stored = requireNotNull(db.items().get(item.id))
            assertEquals("2 lait", stored.label)
            assertNull(stored.quantity)
        }

    @Test
    fun theFormIsCleanedAndAnEmptyLabelSavesNothing() {
        assertNull(ItemEdit.of(" \t ", "2"))
        assertEquals(ItemEdit("lait", "500 g"), ItemEdit.of(" lait ", "  500  g "))
        assertEquals(ItemEdit("lait", null), ItemEdit.of("lait", "   "))
        assertEquals(ItemEdit.MAX_LABEL_LENGTH, ItemEdit.of("a".repeat(300), "")?.label?.length)
    }

    @Test
    fun aReaderCannotEditAnItem() =
        runBlocking {
            val item = sentItem()
            db.lists().setRole(item.listId, ListRole.Viewer)
            val failure = runCatching { repository.applyEdit(ItemEdit("pain", "3"), item.id, analyzer, now) }
            assertTrue(failure.exceptionOrNull() is RepositoryException.ReadOnly)
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(item, db.items().get(item.id))
        }

    @Test
    fun aDeletedListRefusesTheEdit() =
        runBlocking {
            val item = sentItem()
            repository.deleteList(item.listId, now)
            val failure =
                runCatching {
                    repository.updateItem(item.id, item.label, item.normalizedName, item.categoryId, "9", now)
                }
            assertTrue(failure.exceptionOrNull() is RepositoryException.ListDeleted)
        }

    private companion object {
        const val PRODUCT = "11111111-1111-4111-8111-111111111111"
        const val OTHER = "22222222-2222-4222-8222-222222222222"
    }
}
