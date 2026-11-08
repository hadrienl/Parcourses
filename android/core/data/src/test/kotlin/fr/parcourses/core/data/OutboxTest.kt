package fr.parcourses.core.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.outbox.CheckPayload
import fr.parcourses.core.data.outbox.OutboxCoding
import fr.parcourses.core.data.outbox.OutboxQueue
import fr.parcourses.core.data.sync.AccountRekey
import fr.parcourses.core.data.sync.OutboxReconciliation
import fr.parcourses.core.data.sync.ProductCandidate
import fr.parcourses.core.data.sync.ProductMatch
import fr.parcourses.core.data.sync.ProductResolution
import fr.parcourses.core.data.sync.SyncStore
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.dto.ResolvedProductRow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.hours
import kotlin.uuid.Uuid

@RunWith(AndroidJUnit4::class)
@Suppress("LargeClass")
class OutboxTest : DataTest() {
    private val queue by lazy { OutboxQueue(db.outbox()) }
    private val store by lazy { SyncStore(db) }

    private suspend fun kinds() = db.outbox().pending().map { it.kind() to it.entityId }

    // region Ordre des dépendances

    @Test
    fun aListHoldsBackItsItemsUntilItHasLeft() =
        runBlocking {
            val list = insertList()
            val item = insertItem(list.id)
            queue.enqueueUpsert(list, now)
            queue.enqueueUpsert(item, now)
            db.outbox().setNextAttempt(
                db
                    .outbox()
                    .pending()
                    .first()
                    .id,
                now + 1.hours,
            )

            assertNull(store.nextWork(now))
            val other = insertList()
            queue.enqueueUpsert(insertItem(other.id), now)
            // Un autre article, d'une autre liste, n'attend pas.
            assertEquals(other.id, store.nextWork(now)?.let { OutboxKindHelper.listOf(it) })
        }

    @Test
    fun anItemInRetryHoldsItsListDeletionButNotItsSiblings() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val late = insertItem(list.id)
            val sibling = insertItem(list.id, position = 1)
            queue.enqueueUpsert(late, now)
            queue.enqueueUpsert(sibling, now)
            // Sans passer par `enqueueDeletion`, qui purge les articles : on teste les seules dépendances.
            db.outbox().enqueue("delete-list", OutboxKind.DeleteList, list.id, ByteArray(0), now)
            db.outbox().setNextAttempt(
                db
                    .outbox()
                    .pending()
                    .single { it.entityId == late.id }
                    .id,
                now + 1.hours,
            )

            val next = checkNotNull(store.nextWork(now))
            // L'article voisin part ; la suppression attend les deux.
            assertEquals(OutboxKind.UpsertItem, next.kind)
            assertEquals(sibling.id, next.entityId)
            store.complete(next)
            assertNull(store.nextWork(now))
        }

    @Test
    fun checksOfAVisitLeaveInBatchesAndTheClosureWaitsForAllOfThem() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val item = insertItem(list.id)
            val visit = visit(list.id)
            db.visits().upsert(visit)
            queue.enqueueCreation(visit, list.id, now)
            repeat(250) { queue.enqueueInsertion(check(visit.id, item.id).also { db.checks().upsert(it) }, now) }
            queue.enqueueClosure(visit.id, now, now)

            assertEquals(OutboxKind.CreateVisit, store.nextWork(now)?.kind)
            store.complete(store.nextWork(now)!!)
            val batch = checkNotNull(store.nextWork(now))
            assertEquals(OutboxKind.InsertChecks, batch.kind)
            assertEquals(SyncStore.MAX_CHECKS_PER_BATCH, batch.entryIds.size)
            store.complete(batch)
            assertEquals(50, checkNotNull(store.nextWork(now)).entryIds.size)
            store.complete(checkNotNull(store.nextWork(now)))
            assertEquals(OutboxKind.CloseVisit, store.nextWork(now)?.kind)
        }

    @Test
    fun aVisitWaitsForItsList() =
        runBlocking {
            val list = insertList()
            val visit = visit(list.id)
            db.visits().upsert(visit)
            queue.enqueueUpsert(list, now)
            queue.enqueueCreation(visit, list.id, now)
            assertEquals(OutboxKind.UpsertList, store.nextWork(now)?.kind)
            db.outbox().setNextAttempt(
                db
                    .outbox()
                    .pending()
                    .first()
                    .id,
                now + 1.hours,
            )
            assertNull(store.nextWork(now))
        }

    // endregion

    // region Réconciliation

    @Test
    fun reconciliationQueuesWhatHasNoEntryInDependencyOrder() =
        runBlocking {
            val list = insertList()
            val item = insertItem(list.id)
            val visit = visit(list.id)
            val check = check(visit.id, item.id)
            db.visits().upsert(visit.copy(endedAt = now, endSyncState = SyncState.PENDING))
            db.checks().upsert(check)

            val count = OutboxReconciliation(db).run(now)

            assertEquals(5, count)
            assertEquals(
                listOf(
                    OutboxKind.UpsertList,
                    OutboxKind.UpsertItem,
                    OutboxKind.CreateVisit,
                    OutboxKind.InsertChecks,
                    OutboxKind.CloseVisit,
                ),
                db.outbox().pending().map { it.kind() },
            )
            // Rejouable : rien de plus la seconde fois.
            assertEquals(0, OutboxReconciliation(db).run(now))
            assertEquals(5, db.outbox().pending().size)
        }

    @Test
    fun reconciliationSkipsAVisitWithoutChecksAndItemsOfADeletedList() =
        runBlocking {
            val list = insertList()
            val gone = insertList()
            db.lists().markDeleted(gone.id, now)
            insertItem(gone.id)
            db.visits().upsert(visit(list.id))

            OutboxReconciliation(db).run(now)

            assertEquals(
                listOf(OutboxKind.UpsertList to list.id, OutboxKind.DeleteList to gone.id),
                kinds().sortedBy { it.first!!.ordinal },
            )
        }

    @Test
    fun reconciliationReturnsAWronglyAbandonedItemBehindItsList() =
        runBlocking {
            val list = insertList()
            val item = insertItem(list.id)
            queue.enqueueUpsert(item, now)
            val entry = db.outbox().pending().single()
            db.outbox().setState(entry.id, SyncState.FAILED, "42501")
            db.items().setSyncState(item.id, SyncState.FAILED)

            OutboxReconciliation(db).run(now)

            assertTrue(db.outbox().failed().isEmpty())
            assertEquals(
                listOf(OutboxKind.UpsertList to list.id, OutboxKind.UpsertItem to item.id),
                kinds(),
            )
            assertEquals(SyncState.PENDING, db.items().get(item.id)?.syncState)
        }

    @Test
    fun anItemAbandonedForAnotherReasonStaysAbandoned() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val item = insertItem(list.id, state = SyncState.FAILED)
            queue.enqueueUpsert(item, now)
            db.outbox().setState(
                db
                    .outbox()
                    .pending()
                    .single()
                    .id,
                SyncState.FAILED,
                "42501",
            )

            OutboxReconciliation(db).run(now)

            // La liste est reçue : le refus est bien celui de l'article.
            assertEquals(1, db.outbox().failed().size)
            assertTrue(db.outbox().pending().isEmpty())
        }

    // endregion

    // region Reprise de compte

    @Test
    fun rekeyingChangesEveryIdentifierAndRebuildsTheQueueInOrder() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val gone = insertList(state = SyncState.PENDING)
            db.lists().markDeleted(gone.id, now)
            insertItem(gone.id)
            val item = insertItem(list.id, state = SyncState.SYNCED)
            val orphan = insertItem(Uuid.random().toString(), state = SyncState.SYNCED)
            val open = visit(list.id)
            db.visits().upsert(open)
            val held = check(open.id, item.id)
            db.checks().upsert(held)
            queue.enqueueInsertion(held, now, notBefore = now + 1.hours)
            val oldOutbox = db.outbox().all().map { it.id }

            val remap = AccountRekey(db).run(now)

            val newList = db.lists().getAll().single()
            assertNotEquals(list.id, newList.id)
            assertEquals(newList.id, remap[list.id])
            assertEquals("la liste supprimée disparaît", 1, db.lists().getAll().size)
            val newItem = db.items().getAll().single { it.listId == newList.id }
            assertEquals(remap[item.id], newItem.id)
            assertEquals(SyncState.FAILED, db.items().get(remap[orphan.id])?.syncState)
            val newVisit = db.visits().getAll().single()
            assertEquals(newList.id, newVisit.listId)
            assertEquals(remap[open.id], newVisit.id)
            val newCheck = db.checks().getAll().single()
            assertEquals(newVisit.id, newCheck.visitId)
            assertEquals(newItem.id, newCheck.itemId)

            val pending = db.outbox().pending()
            assertTrue(pending.none { it.id in oldOutbox })
            assertEquals(
                listOf(OutboxKind.UpsertList, OutboxKind.UpsertItem, OutboxKind.CreateVisit, OutboxKind.InsertChecks),
                pending.map { it.kind() },
            )
            // La coche retenue garde son délai d'annulation.
            assertEquals(now + 1.hours, pending.last().nextAttemptAt)
        }

    @Test
    fun aReceivedAndClosedVisitChangesIdButIsNeverSentAgain() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val item = insertItem(list.id, state = SyncState.SYNCED)
            val done = visit(list.id, state = SyncState.SYNCED).copy(endedAt = now, endSyncState = SyncState.SYNCED)
            db.visits().upsert(done)
            db.checks().upsert(check(done.id, item.id).copy(syncState = SyncState.SYNCED))
            val unfinished =
                visit(
                    list.id,
                    state = SyncState.SYNCED,
                ).copy(endedAt = now, endSyncState = SyncState.PENDING)
            db.visits().upsert(unfinished)
            db.checks().upsert(check(unfinished.id, item.id).copy(syncState = SyncState.SYNCED))

            val remap = AccountRekey(db).run(now)

            val keptDone = checkNotNull(db.visits().get(remap[done.id]))
            assertEquals(SyncState.SYNCED, keptDone.syncState)
            assertEquals(SyncState.SYNCED, keptDone.endSyncState)
            assertNull(db.visits().get(done.id))
            // Seule la visite non reçue en entier repart.
            val sent =
                db.outbox().pending().filter {
                    it.kind() in
                        setOf(
                            OutboxKind.CreateVisit,
                            OutboxKind.CloseVisit,
                        )
                }
            assertEquals(setOf(remap[unfinished.id]), sent.map { it.entityId }.toSet())
        }

    // endregion

    // region Résolution des produits

    @Test
    fun resolutionRewritesTheQueuedChecksOfTheItemToTheProduct() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val item = insertItem(list.id, state = SyncState.SYNCED)
            val visit = visit(list.id)
            db.visits().upsert(visit)
            val queued = check(visit.id, item.id)
            val sent = check(visit.id, item.id).copy(syncState = SyncState.SYNCED)
            db.checks().upsert(queued)
            db.checks().upsert(sent)
            queue.enqueueInsertion(queued, now)
            val product = Uuid.random()
            val candidate = ProductCandidate(item.id, item.label, "dairy")
            val match = ProductMatch.of(candidate, ResolvedProductRow("lait", product, "Lait", "dairy"))

            val changed = ProductResolution.apply(db, listOf(checkNotNull(match)), now)

            assertTrue(changed)
            assertEquals(product.toString(), db.items().get(item.id)?.productId)
            assertEquals(SyncState.PENDING, db.items().get(item.id)?.syncState)
            assertEquals(
                OutboxKind.UpsertItem,
                db
                    .outbox()
                    .pending()
                    .first { it.entityId == item.id }
                    .kind(),
            )
            val payload =
                OutboxCoding.decode(
                    CheckPayload.serializer(),
                    db
                        .outbox()
                        .pendingFor(queued.id)
                        .single()
                        .payload,
                )
            assertEquals(product.toString(), payload.productId)
            assertNull(payload.categoryId)
            // La coche déjà partie n'est pas touchée.
            assertNull(db.checks().get(sent.id)?.productId)
            assertEquals(product.toString(), db.checks().get(queued.id)?.productId)
            assertNotNull(db.products().get(product.toString()))
        }

    @Test
    fun resolutionIgnoresAnItemWhoseLabelChangedOrWhoseListWasDeleted() =
        runBlocking {
            val list = insertList()
            val edited = insertItem(list.id, label = "lait entier")
            val gone = insertList()
            val orphan = insertItem(gone.id, label = "pain")
            db.lists().markDeleted(gone.id, now)
            val row = ResolvedProductRow("x", Uuid.random(), "X", null)
            val matches =
                listOf(
                    checkNotNull(ProductMatch.of(ProductCandidate(edited.id, "lait", null), row)),
                    checkNotNull(ProductMatch.of(ProductCandidate(orphan.id, "pain", null), row)),
                )

            assertTrue(!ProductResolution.apply(db, matches, now))
            assertNull(db.items().get(edited.id)?.productId)
            assertNull(db.items().get(orphan.id)?.productId)
        }

    @Test
    fun candidatesSkipDeletedListsBlankLabelsAndLabelsAlreadySubmitted() =
        runBlocking {
            val list = insertList()
            val fresh = insertItem(list.id, label = "lait")
            val tried = insertItem(list.id, label = "pain")
            insertItem(list.id, label = "   ")
            insertItem(list.id, label = "riz", productId = Uuid.random().toString())
            val gone = insertList()
            insertItem(gone.id, label = "thé")
            db.lists().markDeleted(gone.id, now)

            val candidates = ProductResolution.candidates(db, mapOf(tried.id to "pain"), limit = 10)
            assertEquals(listOf(fresh.id), candidates.map { it.itemId })
            assertEquals("dairy", candidates.single().categorySlug)
            // Un libellé modifié repart.
            assertEquals(2, ProductResolution.candidates(db, mapOf(tried.id to "autre"), limit = 10).size)
            assertEquals(1, ProductResolution.candidates(db, emptyMap(), limit = 1).size)
        }

    // endregion
}

/** Liste visée par un lot d'articles. */
private object OutboxKindHelper {
    fun listOf(work: fr.parcourses.core.data.sync.OutboxWork): String? =
        fr.parcourses.core.data.outbox.OutboxDependencies
            .listId(
                fr.parcourses.core.database.entity.OutboxEntryEntity(
                    id = "",
                    sequence = 0,
                    kindRaw = work.kind.raw,
                    entityId = work.entityId,
                    payload = work.payloads.first(),
                    createdAt = kotlin.time.Instant.fromEpochSeconds(0),
                    nextAttemptAt = kotlin.time.Instant.fromEpochSeconds(0),
                ),
            )
}
