package fr.parcourses.core.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.outbox.ItemFields
import fr.parcourses.core.data.outbox.OutboxQueue
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.sync.AccountRekey
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.dto.ListItemFields
import fr.parcourses.core.network.dto.ListItemRow
import fr.parcourses.core.network.dto.ListRow
import fr.parcourses.core.network.dto.TombstoneRow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.uuid.Uuid

/** Synchro multi-appareil et partage côté moteur (#87, lot 87.5) : envoi par champ, pierres tombales, accès. */
@RunWith(AndroidJUnit4::class)
class SyncSharingTest : DataTest() {
    private val gateway = fakeGateway()
    private val cursors = InMemorySyncCursors()
    private val engine by lazy { SyncEngine(gateway, db, cursors, classify, dependencies) }
    private val repository by lazy { RoomListRepository(db) }

    private val me get() = gateway.account

    /** Une liste et un article descendus du serveur (donc `isOnServer`), à [owner]. */
    private suspend fun pulled(owner: Uuid = me): Pair<String, String> {
        val listId = Uuid.random()
        val itemId = Uuid.random()
        gateway.remoteLists = listOf(ListRow(listId, owner, "Partagée", now, now))
        gateway.remoteItems = listOf(ListItemRow(itemId, listId, null, "lait", "1", null, now, now, owner))
        // Heure du serveur : curseur des pierres tombales posé par la réconciliation complète.
        gateway.serverDate = now - 1.minutes
        engine.drain(pull = true)
        // Premier passage : réconciliation complète des suppressions, curseur posé.
        check(gateway.callsOf("fetchItemIds").isNotEmpty() && cursors.tombstones != null)
        gateway.calls.clear()
        return listId.toString() to itemId.toString()
    }

    @Test
    fun aPulledItemSendsOnlyItsChangedFields() =
        runBlocking {
            val (listId, itemId) = pulled()
            val item = checkNotNull(db.items().get(itemId))
            assertTrue(item.isOnServer)
            assertEquals(me.toString(), item.updatedBy)
            assertEquals(me.toString(), db.lists().get(listId)?.ownerId)

            repository.setChecked(itemId, now, now)
            engine.drain()

            assertTrue(gateway.callsOf("insertItem").isEmpty())
            assertEquals(listOf(ItemFields.CHECKED_AT), gateway.patches.single().columns)
            assertTrue(db.outbox().all().isEmpty())
        }

    @Test
    fun twoChangesBeforeTheSendKeepTheUnionOfTheirFields() =
        runBlocking {
            val (_, itemId) = pulled()
            val queue = OutboxQueue(db.outbox())
            val item = checkNotNull(db.items().get(itemId))
            queue.enqueueUpsert(item, now, listOf(ItemFields.QUANTITY))
            queue.enqueueUpsert(item, now, listOf(ItemFields.CHECKED_AT))
            assertEquals(
                "checked_at,quantity",
                db
                    .outbox()
                    .pending()
                    .single()
                    .changedFields,
            )

            engine.drain()

            assertEquals(listOf(ItemFields.CHECKED_AT, ItemFields.QUANTITY), gateway.patches.single().columns)
        }

    @Test
    fun aNewItemIsInsertedThenOnlyPatched() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val item = repository.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            engine.drain()
            assertEquals(1, gateway.callsOf("insertItem").size)
            assertTrue(checkNotNull(db.items().get(item.id)).isOnServer)

            repository.setChecked(item.id, now, now)
            engine.drain()
            assertEquals(1, gateway.callsOf("insertItem").size)
            assertEquals(1, gateway.callsOf("updateItem").size)
        }

    @Test
    fun anEntryWrittenBeforeVersion2KeepsTheFormerSend() =
        runBlocking {
            val (_, itemId) = pulled()
            repository.setChecked(itemId, now, now)
            // Entrée d'avant la migration : aucun champ connu.
            val entry = db.outbox().pending().single()
            db.outbox().delete(entry.id)
            db.outbox().enqueue(entry.id, OutboxKind.UpsertItem, itemId, entry.payload, now)
            gateway.rowTouched = { false }

            engine.drain()

            assertEquals(
                4 + 1,
                gateway.patches
                    .single()
                    .columns.size,
            )
            assertEquals(1, gateway.callsOf("insertItem").size)
            assertTrue(gateway.callsOf("fetchTombstonesOf").isEmpty())
        }

    @Test
    fun aPatchWithoutRowOnATombstonedItemDropsItWithoutRetry() =
        runBlocking {
            val (listId, itemId) = pulled()
            repository.setChecked(itemId, now, now)
            gateway.rowTouched = { false }
            gateway.tombstones = listOf(TombstoneRow(Uuid.parse(itemId), Uuid.parse(listId), now))

            engine.drain()

            assertNull(db.items().get(itemId))
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(1, gateway.callsOf("updateItem").size)
            assertTrue(gateway.callsOf("fetchItemsOfList").isEmpty())
        }

    @Test
    fun aPatchWithoutRowAndWithoutTombstoneReloadsTheList() =
        runBlocking {
            val (listId, itemId) = pulled(owner = Uuid.random())
            val local = repository.addItem(listId, "beurre", "beurre", null, null, "dairy", now)
            repository.setChecked(itemId, now, now)
            gateway.rowTouched = { false }
            // L'insertion du nouvel article est refusée : lecteur.
            gateway.failNext("insertItem", RemoteError.Forbidden())

            engine.drain()

            // Rôle abaissé : les écritures en attente sont jetées, la liste reprend les articles du serveur.
            assertTrue(gateway.callsOf("fetchItemsOfList").isNotEmpty())
            assertNull(db.items().get(local.id))
            val reloaded = checkNotNull(db.items().get(itemId))
            assertNull(reloaded.checkedAt)
            assertEquals(SyncState.SYNCED, reloaded.syncState)
            assertTrue(db.outbox().all().isEmpty())
        }

    @Test
    fun aRefusedInsertInAListOfMineIsAbandonedAsBefore() =
        runBlocking {
            val (listId, _) = pulled()
            repository.addItem(listId, "beurre", "beurre", null, null, "dairy", now)
            gateway.failNext("insertItem", RemoteError.Forbidden())

            engine.drain()

            assertEquals(
                SyncState.FAILED,
                db
                    .outbox()
                    .all()
                    .single()
                    .syncState,
            )
            assertTrue(gateway.callsOf("fetchItemsOfList").isEmpty())
        }

    @Test
    fun aListThatIsNoLongerAccessibleLeavesTheDeviceWithItsPendingEntries() =
        runBlocking {
            val (listId, itemId) = pulled()
            val draft = repository.createList("Brouillon", now)
            repository.setChecked(itemId, now, now)
            db.outbox().pending().forEach { db.outbox().setNextAttempt(it.id, now + 1.days) }
            gateway.accessible = { emptyList() }
            gateway.remoteLists = emptyList()
            gateway.remoteItems = emptyList()

            engine.drain(pull = true)

            assertNull(db.lists().get(listId))
            assertNull(db.items().get(itemId))
            assertTrue(db.outbox().pendingFor(itemId).isEmpty())
            // Jamais envoyée : gardée, son entrée aussi.
            assertNotNull(db.lists().get(draft.id))
            assertEquals(listOf(draft.id), db.outbox().pending().map { it.entityId })
        }

    @Test
    fun aNewlyAccessibleListIsPulledEntirely() =
        runBlocking {
            pulled()
            val shared = Uuid.random()
            val owner = Uuid.random()
            val old = now - 3.days
            // Ses lignes sont plus anciennes que les curseurs : seule la descente complète les apporte.
            val listRow = ListRow(shared, owner, "De Léa", old, old)
            val itemRow = ListItemRow(Uuid.random(), shared, null, "œufs", "6", null, old, old, owner)
            gateway.remoteLists = gateway.remoteLists + listRow
            gateway.remoteItems = gateway.remoteItems + itemRow

            engine.drain(pull = true)

            assertEquals(owner.toString(), db.lists().get(shared.toString())?.ownerId)
            assertEquals("œufs", db.items().get(itemRow.id.toString())?.label)
            assertTrue(gateway.calls.contains("fetchItemsOfList:$shared"))
        }

    @Test
    fun tombstonesRemoveItemsAndTheirEntries() =
        runBlocking {
            val (listId, itemId) = pulled()
            val cursor = checkNotNull(cursors.tombstones)
            repository.setChecked(itemId, now, now)
            db.outbox().pending().forEach { db.outbox().setNextAttempt(it.id, now + 1.days) }
            gateway.tombstones = listOf(TombstoneRow(Uuid.parse(itemId), Uuid.parse(listId), cursor + 1.minutes))

            engine.drain(pull = true)

            // La suppression gagne : article et entrée partent.
            assertNull(db.items().get(itemId))
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(cursor + 1.minutes, cursors.tombstones)
            assertTrue(gateway.callsOf("fetchTombstones").isNotEmpty())
        }

    @Test
    fun anOldCursorReconcilesItemsListByList() =
        runBlocking {
            val (listId, itemId) = pulled()
            val local = repository.addItem(listId, "pain", "pain", null, null, "bakery", now)
            db.outbox().pending().forEach { db.outbox().setNextAttempt(it.id, now + 1.days) }
            cursors.tombstones = now - 30.days
            gateway.remoteItems = emptyList()

            engine.drain(pull = true)

            // Supprimé ailleurs (absent du serveur) ; l'article jamais envoyé reste.
            assertNull(db.items().get(itemId))
            assertNotNull(db.items().get(local.id))
            assertTrue(gateway.calls.contains("fetchItemIds:$listId"))
        }

    @Test
    fun deletingAnItemNeverSentDoesNotQuestionTheAccess() =
        runBlocking {
            val list = repository.createList("Courses", now)
            engine.drain()
            val item = repository.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            repository.deleteItem(item.id, now)
            gateway.rowTouched = { false }

            engine.drain()

            assertTrue(gateway.callsOf("fetchTombstonesOf").isEmpty())
            assertTrue(db.outbox().all().isEmpty())
        }

    @Test
    fun deletingAnItemThatHasNoRowAnymoreIsDecidedByItsTombstone() =
        runBlocking {
            val (listId, itemId) = pulled()
            repository.deleteItem(itemId, now)
            gateway.rowTouched = { false }
            gateway.tombstones = listOf(TombstoneRow(Uuid.parse(itemId), Uuid.parse(listId), now))

            engine.drain()

            assertEquals(1, gateway.callsOf("fetchTombstonesOf").size)
            assertTrue(gateway.callsOf("fetchItemsOfList").isEmpty())
            assertTrue(db.outbox().all().isEmpty())
            assertFalse(gateway.callsOf("deleteItem").isEmpty())
        }

    /** Les dates du serveur : la liste « Courses » jamais modifiée reste « vide intacte » pour la reprise (iOS). */
    @Test
    fun aPulledListTakesBothServerDatesAndAnUntouchedOneIsNotResent() =
        runBlocking {
            val list = repository.createList("Courses", now)
            engine.drain()
            val serverAt = now - 1.hours
            gateway.remoteLists = listOf(ListRow(Uuid.parse(list.id), me, "Courses", serverAt, serverAt))
            engine.drain(pull = true)
            val pulled = checkNotNull(db.lists().get(list.id))
            assertEquals(serverAt, pulled.createdAt)
            assertEquals(serverAt, pulled.updatedAt)

            val result = AccountRekey(db).run(now, previousAccountId = me.toString())
            assertEquals(0, result.resentLists)
            assertTrue(db.lists().getAll().isEmpty())
        }

    /** Sans ancien compte connu, une liste au propriétaire connu n'est pas renvoyée (même règle qu'iOS). */
    @Test
    fun withoutAPreviousAccountAListWithAKnownOwnerIsDropped() =
        runBlocking {
            pulled()
            val draft = repository.createList("Brouillon", now - 1.minutes)
            repository.renameList(draft.id, "Brouillon", now)

            val result = AccountRekey(db).run(now, previousAccountId = null)

            assertEquals(1, result.resentLists)
            assertEquals(listOf("Brouillon"), db.lists().getAll().map { it.name })
        }

    /**
     * Règle 1 (relecture de #93) : une insertion qui n'insère rien (réponse d'une insertion précédente perdue) enchaîne
     * une mise à jour des champs de l'entrée ; une mise à jour sans ligne suit le chemin « 0 ligne ».
     */
    @Test
    fun anInsertThatInsertsNothingSendsItsFieldsAsAnUpdate() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val item = repository.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            repository.setChecked(item.id, now, now)
            gateway.inserted = { it.toString() != item.id }

            engine.drain()

            assertEquals(1, gateway.callsOf("insertItem").size)
            assertEquals(ListItemFields.ALL, gateway.patches.single().columns)
            assertTrue(checkNotNull(db.items().get(item.id)).isOnServer)
            assertTrue(db.outbox().all().isEmpty())

            // Enterré ailleurs : rien d'inséré, rien de mis à jour, la pierre tombale tranche.
            val other = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            gateway.inserted = { false }
            gateway.rowTouched = { false }
            gateway.tombstones = listOf(TombstoneRow(Uuid.parse(other.id), Uuid.parse(list.id), now))
            engine.drain()
            assertNull(db.items().get(other.id))
            assertTrue(db.outbox().all().isEmpty())
        }

    /** Règle 4 : `refreshAccess` sur une liste à soi garde les articles jamais envoyés et leurs entrées. */
    @Test
    fun refreshingTheAccessOfMyListKeepsItsUnsentItems() =
        runBlocking {
            val (listId, itemId) = pulled()
            val draft = repository.addItem(listId, "beurre", "beurre", null, null, "dairy", now)
            db.outbox().pendingFor(draft.id).forEach { db.outbox().setNextAttempt(it.id, now + 1.days) }
            repository.setChecked(itemId, now, now)
            gateway.rowTouched = { false }

            engine.drain()

            assertTrue(gateway.callsOf("fetchItemsOfList").isNotEmpty())
            assertNull(checkNotNull(db.items().get(itemId)).checkedAt)
            assertNotNull(db.items().get(draft.id))
            assertEquals(listOf(draft.id), db.outbox().pending().map { it.entityId })
        }
}
