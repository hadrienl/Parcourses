package fr.parcourses.core.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.outbox.ItemDeletionPayload
import fr.parcourses.core.data.outbox.OutboxCoding
import fr.parcourses.core.data.outbox.OutboxQueue
import fr.parcourses.core.data.repository.RepositoryException
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.dto.ListItemUpsert
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.seconds

@RunWith(AndroidJUnit4::class)
class RoomListRepositoryTest : DataTest() {
    private var wakeUps = 0
    private val repository by lazy { RoomListRepository(db, onEnqueue = { wakeUps++ }) }

    private suspend fun kinds() = db.outbox().pending().map { it.kind() }

    @Test
    fun creatingAListWritesItAndQueuesItInTheSameTransaction() =
        runBlocking {
            val list = repository.createList("Courses", now)
            assertEquals(SyncState.PENDING, db.lists().get(list.id)?.syncState)
            assertEquals(listOf(OutboxKind.UpsertList), kinds())
            assertEquals(
                list.id,
                db
                    .outbox()
                    .pending()
                    .single()
                    .entityId,
            )
            assertEquals(1, wakeUps)
        }

    @Test
    fun aFailedQueueWriteLeavesNothingBehind() =
        runBlocking {
            val failing =
                RoomListRepository(
                    db,
                    queue = OutboxQueue(db.outbox(), newId = { error("file indisponible") }),
                )
            runCatching { failing.createList("Courses", now) }
            assertTrue(db.lists().getAll().isEmpty())
            assertTrue(db.outbox().all().isEmpty())
        }

    @Test
    fun renamingKeepsTheRankOfTheListAheadOfItsItems() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val item = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            advance(1.seconds)
            repository.renameList(list.id, "Semaine", now)
            val pending = db.outbox().pending()
            assertEquals(listOf(list.id, item.id), pending.map { it.entityId })
            assertEquals("Semaine", repository.list(list.id)?.name)
        }

    @Test
    fun deletingAListPurgesTheQueuedEntriesOfItsItems() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val other = repository.createList("Autre", now)
            val milk = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val bread = repository.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val keep = repository.addItem(other.id, "riz", "riz", null, null, "savory-grocery", now)
            repository.deleteItem(bread.id, now)
            assertTrue(db.outbox().pending().any { it.kind() == OutboxKind.DeleteItem })

            repository.deleteList(list.id, now)

            val pending = db.outbox().pending()
            // Plus rien de la liste ni de ses articles : ni upsert, ni suppression d'article.
            val doomed = setOf(list.id, milk.id, bread.id)
            assertFalse(pending.any { it.entityId in doomed && it.kind() != OutboxKind.DeleteList })
            assertEquals(1, pending.count { it.kind() == OutboxKind.DeleteList && it.entityId == list.id })
            assertTrue(pending.any { it.entityId == keep.id })
            assertTrue(pending.any { it.entityId == other.id })
            assertNull(repository.list(list.id))
            assertTrue(repository.items(list.id).isEmpty())
            assertNotNull(db.lists().get(list.id)?.deletedAt)
        }

    @Test
    fun aDeletedListRefusesWrites() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val item = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            repository.deleteList(list.id, now)

            fun failure(block: suspend () -> Unit) = runBlocking { runCatching { block() }.exceptionOrNull() }
            val deleted = RepositoryException.ListDeleted::class
            assertEquals(
                deleted,
                failure { repository.addItem(list.id, "x", "x", null, null, "other", now) }?.let { it::class },
            )
            assertEquals(deleted, failure { repository.setChecked(item.id, now, now) }?.let { it::class })
            assertEquals(deleted, failure { repository.renameList(list.id, "y", now) }?.let { it::class })
            assertEquals(deleted, failure { repository.deleteItem(item.id, now) }?.let { it::class })
            assertTrue(failure { repository.renameList("inconnue", "y", now) } is RepositoryException.NotFound)
        }

    @Test
    fun itemsGetIncreasingPositionsAndTheLatestValueIsQueuedOnce() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val a = repository.addItem(list.id, "lait", "lait", "1 L", null, "dairy", now)
            val b = repository.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            assertEquals(listOf(0, 1), listOf(a.position, b.position))

            advance(5.seconds)
            repository.setChecked(a.id, now, now)
            repository.setChecked(a.id, null, now)
            repository.setChecked(a.id, now, now)

            val entries = db.outbox().pending().filter { it.entityId == a.id }
            assertEquals(1, entries.size)
            val row = OutboxCoding.decode(ListItemUpsert.serializer(), entries.single().payload)
            assertEquals(now, row.checkedAt)
            assertEquals("1 L", row.quantity)
            assertEquals(now, db.items().get(a.id)?.checkedAt)
        }

    @Test
    fun deletingAnItemCancelsItsUpsertAndQueuesTheDeletionWithItsList() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val item = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            repository.deleteItem(item.id, now)
            val entry = db.outbox().pending().single { it.entityId == item.id }
            assertEquals(OutboxKind.DeleteItem, entry.kind())
            assertEquals(list.id, OutboxCoding.decode(ItemDeletionPayload.serializer(), entry.payload).listId)
            assertNull(db.items().get(item.id))
        }

    @Test
    fun notFoundStaysLocal() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val item = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val before = db.outbox().all()
            repository.setNotFound(item.id, now)
            assertEquals(before, db.outbox().all())
            assertEquals(now, db.items().get(item.id)?.notFoundAt)
            assertEquals(item.updatedAt, db.items().get(item.id)?.updatedAt)
        }

    @Test
    fun summariesFollowTheWritesAndHideDeletedLists() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val gone = repository.createList("Vieille", now)
            val a = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            repository.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            repository.setChecked(a.id, now, now)
            repository.deleteList(gone.id, now)

            val summaries = repository.observeSummaries().first()
            assertEquals(listOf(list.id), summaries.map { it.id })
            assertEquals(1, summaries.single().remaining)
            assertEquals(2, summaries.single().total)
            assertEquals(2, repository.observeItems(list.id).first().size)
            assertTrue(repository.observeItems(gone.id).first().isEmpty())
            assertNull(repository.observeList(gone.id).first())
        }
}
