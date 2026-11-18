package fr.parcourses.core.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.outbox.OutboxQueue
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.dto.CategoryRow
import fr.parcourses.core.network.dto.ListItemRow
import fr.parcourses.core.network.dto.ListRow
import fr.parcourses.core.network.dto.RemoteProduct
import fr.parcourses.core.network.dto.RemoteUnpublishedProduct
import fr.parcourses.core.network.dto.ResolvedProductRow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.uuid.Uuid

@RunWith(AndroidJUnit4::class)
@Suppress("LargeClass")
class SyncEngineTest : DataTest() {
    private val gateway = fakeGateway()
    private val cursors = InMemorySyncCursors()
    private val engine by lazy { SyncEngine(gateway, db, cursors, classify, dependencies) }
    private val repository by lazy { RoomListRepository(db) }

    private suspend fun entries() = db.outbox().all()

    /** Liste renommée après sa création : la reprise de compte la renvoie (une liste vide intacte ne l'est pas, #87). */
    private suspend fun modifiedList() =
        repository.createList("Courses", now - 1.minutes).also { repository.renameList(it.id, "Courses", now) }

    /** Entrées différées d'une heure : elles restent en file, donc leurs lignes serveur sont sautées. */
    private suspend fun holdQueue() = db.outbox().pending().forEach { db.outbox().setNextAttempt(it.id, now + 1.hours) }

    // region Envoi

    @Test
    fun theListLeavesBeforeItsItemsAndAfterTheProductResolution() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val milk = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val bread = repository.addItem(list.id, "pain", "pain", null, null, "bakery", now)

            assertNull(engine.drain())

            val sends = gateway.calls.filter { it.startsWith("saveList") || it.startsWith("insertItem") }
            assertEquals(listOf("saveList:${list.id}", "insertItem:${milk.id}", "insertItem:${bread.id}"), sends)
            // La résolution des produits passe avant l'envoi (SYNC.md).
            assertTrue(gateway.calls.indexOf("resolveProducts") < gateway.calls.indexOfFirst { it.startsWith("save") })
            assertTrue(entries().isEmpty())
            assertEquals(SyncState.SYNCED, db.lists().get(list.id)?.syncState)
            assertEquals(SyncState.SYNCED, db.items().get(milk.id)?.syncState)
        }

    @Test
    fun aMalformedUuidOrDateInAPayloadIsRejectedWithoutBlockingTheQueue() =
        runBlocking {
            // Charges lisibles en JSON, mais un UUID ou une date qui ne se décode pas (#120).
            val badList = Uuid.random().toString()
            val visit = Uuid.random().toString()
            db.outbox().enqueue(
                "bad-list",
                OutboxKind.UpsertList,
                badList,
                """{"id":"pas-un-uuid","name":"Courses"}""".encodeToByteArray(),
                now,
            )
            db.outbox().enqueue(
                "bad-check",
                OutboxKind.InsertChecks,
                Uuid.random().toString(),
                """{"id":"pas-un-uuid","visitId":"$visit","productId":null,"categoryId":"dairy","checkedAt":"$now"}"""
                    .encodeToByteArray(),
                now,
            )
            db.outbox().enqueue(
                "bad-close",
                OutboxKind.CloseVisit,
                visit,
                """{"visitId":"$visit","endedAt":"pas-une-date"}""".encodeToByteArray(),
                now,
            )
            val list = repository.createList("Courses", now)

            val wake = engine.drain()

            // Aucune nouvelle tentative : les trois entrées sont `FAILED` en `Rejected("payload")`.
            assertNull(wake)
            val failed = entries().filter { it.id.startsWith("bad-") }
            assertEquals(setOf("bad-list", "bad-check", "bad-close"), failed.map { it.id }.toSet())
            failed.forEach {
                assertEquals(SyncState.FAILED, it.syncState)
                assertTrue(it.lastError.orEmpty(), it.lastError.orEmpty().contains("rejected payload"))
            }
            // La liste suivante part quand même.
            assertEquals(listOf("saveList:${list.id}"), gateway.callsOf("saveList"))
            assertEquals(SyncState.SYNCED, db.lists().get(list.id)?.syncState)

            // Une nouvelle passe ne les rejoue pas.
            advance(1.hours)
            engine.drain()
            assertEquals(1, gateway.callsOf("saveList").size)
            assertTrue(gateway.callsOf("insertChecks").isEmpty())
            assertTrue(gateway.callsOf("closeVisit").isEmpty())
        }

    @Test
    fun anUnreadableDeletionListOrUnknownChangedFieldsAreRejected() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val milk = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            engine.drain()
            assertTrue(entries().isEmpty())

            // Suppression dont la liste ne se lit pas (#120).
            db.outbox().enqueue(
                "bad-deletion",
                OutboxKind.DeleteItem,
                Uuid.random().toString(),
                """{"listId":"pas-un-uuid","isOnServer":true}""".encodeToByteArray(),
                now,
            )
            // Coche d'un article déjà sur le serveur, avec une colonne inconnue parmi les champs modifiés.
            repository.setChecked(milk.id, now, now)
            val check = entries().single { it.entityId == milk.id }
            db.outbox().replacePending(
                "bad-fields",
                OutboxKind.UpsertItem,
                milk.id,
                check.payload,
                now,
                changedFields = "colonne_inconnue",
            )

            assertNull(engine.drain())

            val failed = entries()
            assertEquals(setOf("bad-deletion", "bad-fields"), failed.map { it.id }.toSet())
            failed.forEach {
                assertEquals(SyncState.FAILED, it.syncState)
                assertTrue(it.lastError.orEmpty(), it.lastError.orEmpty().contains("rejected payload"))
            }
            assertTrue(gateway.callsOf("deleteItem").isEmpty())
            assertTrue(gateway.callsOf("updateItem").isEmpty())
        }

    @Test
    fun aNetworkErrorWaitsWithoutConsumingAnAttempt() =
        runBlocking {
            val list = repository.createList("Courses", now)
            gateway.failNext("saveList", RemoteError.Network())

            val wake = engine.drain()

            assertEquals(now + 2.seconds, wake)
            val entry = entries().single()
            assertEquals(0, entry.attempts)
            assertEquals(SyncState.PENDING, entry.syncState)
            // Avant la fin du délai, rien ne repart.
            engine.drain()
            assertEquals(1, gateway.callsOf("saveList").size)

            advance(3.seconds)
            engine.drain()
            assertTrue(entries().isEmpty())
            assertEquals(SyncState.SYNCED, db.lists().get(list.id)?.syncState)
        }

    @Test
    fun backoffGrowsWithRepeatedTransientFailuresUpToFiveMinutes() =
        runBlocking {
            repository.createList("Courses", now)
            gateway.failNext("saveList", RemoteError.Network(), times = 30)
            val delays = mutableListOf<Long>()
            repeat(12) {
                val wake = checkNotNull(engine.drain())
                delays += (wake - now).inWholeSeconds
                now = wake
            }
            assertEquals(listOf(2L, 4L, 8L, 16L, 32L, 64L, 128L, 256L, 300L, 300L, 300L, 300L), delays)
        }

    @Test
    fun forbiddenItemWaitsForAListThatHasNotLeftYet() =
        runBlocking {
            // Liste créée avant l'existence de la file : `PENDING` sans entrée.
            val list = insertList()
            val item = insertItem(list.id)
            repository.setChecked(item.id, null, now)
            gateway.failNext("insertItem", RemoteError.Forbidden())

            val wake = engine.drain()

            // La liste est partie (réconciliation) ; l'article attend 30 s, sans essai consommé ni abandon.
            assertEquals(SyncState.SYNCED, db.lists().get(list.id)?.syncState)
            val entry = entries().single()
            assertEquals(item.id, entry.entityId)
            assertEquals(0, entry.attempts)
            assertEquals(SyncState.PENDING, entry.syncState)
            assertEquals(now + 30.seconds, entry.nextAttemptAt)
            assertEquals(now + 30.seconds, wake)

            advance(31.seconds)
            engine.drain()
            assertTrue(entries().isEmpty())
            assertEquals(SyncState.SYNCED, db.items().get(item.id)?.syncState)
        }

    @Test
    fun forbiddenItemOfAReceivedListIsAbandonedWith42501() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val item = insertItem(list.id)
            repository.setChecked(item.id, null, now)
            gateway.failNext("insertItem", RemoteError.Forbidden())

            engine.drain()

            val entry = entries().single()
            assertEquals(SyncState.FAILED, entry.syncState)
            assertEquals("42501", entry.lastError)
            assertEquals(SyncState.FAILED, db.items().get(item.id)?.syncState)
            assertTrue(gateway.callsOf("verifySession").isNotEmpty())
        }

    @Test
    fun aMissingParentIsRetriedEightTimesThenAbandoned() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val item = insertItem(list.id)
            repository.setChecked(item.id, null, now)
            gateway.failNext("insertItem", RemoteError.DependencyMissing("23503"), times = 50)

            repeat(10) {
                engine.drain()
                advance(10.minutes)
            }

            assertEquals(8, gateway.callsOf("insertItem").size)
            val entry = entries().single()
            assertEquals(SyncState.FAILED, entry.syncState)
            assertEquals(7, entry.attempts)
        }

    @Test
    fun aServerErrorHoldsTheQueueDuringTheGraceThenParksTheLine() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val first = insertItem(list.id, position = 0)
            val second = insertItem(list.id, position = 1)
            repository.setChecked(first.id, null, now)
            repository.setChecked(second.id, null, now)
            gateway.failNext("insertItem:${first.id}", RemoteError.Server("500"), times = 3)

            engine.drain()
            // Dans le délai de grâce : toute la file attend, rien n'est mis de côté.
            assertEquals(1, gateway.callsOf("insertItem").size)
            assertEquals(2, entries().size)

            advance(4.hours + 1.minutes)
            engine.drain()

            // Passé 4 h, la première ligne part de côté 6 h (jamais `FAILED`) et ne retient plus la suivante.
            val parked = entries().single { it.entityId == first.id }
            assertEquals(SyncState.PENDING, parked.syncState)
            assertEquals(0, parked.attempts)
            assertEquals(now + 6.hours, parked.nextAttemptAt)
            // Le succès de la seconde prouve la reprise : la ligne mise de côté repart une fois, échoue, retourne de côté.
            val sends = gateway.callsOf("insertItem").map { it.substringAfter(':') }
            assertEquals(listOf(first.id, first.id, second.id, first.id), sends)
        }

    @Test
    fun anUnknownCategoryStaysPendingAnHourAtATime() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val item = insertItem(list.id)
            val visit = visit(list.id)
            val check = check(visit.id, item.id)
            db.visits().upsert(visit)
            db.checks().upsert(check)
            OutboxQueue(db.outbox())
                .enqueueInsertion(check, now)
            gateway.failNext("insertChecks", RemoteError.UnknownCategory("bio"))

            engine.drain()

            val entry = entries().single()
            assertEquals(SyncState.PENDING, entry.syncState)
            assertEquals(now + 1.hours, entry.nextAttemptAt)
            assertEquals(1, entry.attempts)
            assertEquals(SyncState.PENDING, db.checks().get(check.id)?.syncState)
        }

    @Test
    fun aBatchRefusedForARowIsRetriedRowByRow() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val item = insertItem(list.id)
            val visit = visit(list.id, state = SyncState.SYNCED)
            db.visits().upsert(visit)
            val queue = OutboxQueue(db.outbox())
            val checks = listOf(check(visit.id, item.id), check(visit.id, item.id), check(visit.id, item.id))
            checks.forEach {
                db.checks().upsert(it)
                queue.enqueueInsertion(it, now)
            }
            gateway.failNext("insertChecks", RemoteError.Constraint("23505"))

            engine.drain()

            // Un lot de 3, refusé ; puis trois envois d'une coche (la fautive est isolée sans essai consommé).
            assertEquals(listOf("3", "1", "1", "1"), gateway.callsOf("insertChecks").map { it.substringAfter(':') })
            assertTrue(entries().isEmpty())
        }

    // endregion

    // region Descente

    @Test
    fun pullsOnOpenAndMergesWithoutOverwritingPendingRows() =
        runBlocking {
            val kept = insertList(state = SyncState.PENDING)
            repository.renameList(kept.id, "Local", now)
            holdQueue()
            val remoteId = Uuid.random()
            val owner = Uuid.random()
            gateway.remoteLists =
                listOf(
                    ListRow(Uuid.parse(kept.id), owner, "Serveur", now - 1.hours, now - 1.hours),
                    ListRow(remoteId, owner, "Distante", now - 2.hours, now - 2.hours),
                )
            gateway.remoteItems =
                listOf(
                    ListItemRow(Uuid.random(), remoteId, null, "2 yaourts", "2", null, now - 2.hours, now - 2.hours),
                )

            engine.drain(pull = true)

            // La liste locale en attente n'est pas écrasée (le local partira) ; la distante arrive.
            assertEquals("Local", db.lists().get(kept.id)?.name)
            assertEquals("Distante", db.lists().get(remoteId.toString())?.name)
            assertEquals(SyncState.SYNCED, db.lists().get(remoteId.toString())?.syncState)
            val pulled = db.items().getByList(remoteId.toString()).single()
            assertEquals("2 yaourts", pulled.label)
            assertEquals("dairy", pulled.categoryId)
            assertEquals(0, pulled.position)
        }

    @Test
    fun aWriteMadeBetweenTheFetchAndTheMergeIsNotOverwritten() =
        runBlocking {
            // #54 : l'écran coche un article pendant la descente, après la lecture du serveur, avant la fusion.
            val list = insertList(state = SyncState.SYNCED)
            val milk = insertItem(list.id, state = SyncState.SYNCED)
            val owner = Uuid.random()
            gateway.remoteLists = listOf(ListRow(Uuid.parse(list.id), owner, "Liste", now, now - 10.minutes))
            gateway.remoteItems =
                listOf(
                    ListItemRow(
                        Uuid.parse(milk.id),
                        Uuid.parse(list.id),
                        null,
                        "lait entier",
                        null,
                        null,
                        now,
                        now - 1.minutes,
                    ),
                )
            gateway.beforeCall = { method ->
                if (method == "fetchItems") repository.setChecked(milk.id, now, now)
            }

            engine.drain(pull = true)

            // La coche locale reste, en attente d'envoi ; la version lue avant elle n'est pas appliquée.
            val local = db.items().get(milk.id)!!
            assertEquals(now, local.checkedAt)
            assertEquals("lait", local.label)
            assertEquals(SyncState.PENDING, local.syncState)
            assertTrue(db.outbox().pendingFor(milk.id).isNotEmpty())
            // Le curseur ne passe pas la ligne sautée : elle sera relue à la descente suivante.
            assertEquals(now - 1.minutes, cursors.items)
        }

    @Test
    fun theCursorNeverPassesASkippedRow() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val skipped = insertItem(list.id)
            repository.setChecked(skipped.id, null, now)
            holdQueue()
            val owner = Uuid.random()
            val other = Uuid.random()
            gateway.remoteLists = listOf(ListRow(Uuid.parse(list.id), owner, "L", now, now - 10.minutes))
            gateway.remoteItems =
                listOf(
                    ListItemRow(
                        Uuid.parse(skipped.id),
                        Uuid.parse(list.id),
                        null,
                        "lait",
                        null,
                        null,
                        now,
                        now - 5.minutes,
                    ),
                    ListItemRow(other, Uuid.parse(list.id), null, "pain", null, null, now, now - 1.minutes),
                )

            engine.drain(pull = true)

            // Le parent est à jour ; pour les articles, le curseur reste avant la ligne sautée.
            assertEquals(now - 10.minutes, cursors.lists)
            assertEquals(now - 5.minutes, cursors.items)
        }

    @Test
    fun theCatalogIsPulledOncePerDay() =
        runBlocking {
            engine.drain(pull = true)
            engine.drain(pull = true)
            assertEquals(1, gateway.callsOf("fetchCategories").size)
            assertEquals(2, gateway.callsOf("fetchLists").size)

            advance(25.hours)
            engine.drain(pull = true)
            assertEquals(2, gateway.callsOf("fetchCategories").size)
        }

    /** #69 : un catalogue vide mais lisible (catégories reçues) vide le cache ; illisible, il le laisse intact. */
    @Test
    fun aReadableEmptyCatalogClearsTheCache() =
        runBlocking {
            val category = CategoryRow(7, "dairy", "Crèmerie", 1)
            gateway.remoteCategories = listOf(category)
            gateway.remoteProducts =
                listOf(RemoteProduct(Uuid.random(), "Médicament de Paul", "medicament de paul", "dairy", null, now))
            engine.drain(pull = true)
            assertEquals(1, db.products().getAll().size)

            // Réponse vide sans catégories (catalogue illisible) : cache intact.
            gateway.remoteCategories = emptyList()
            gateway.remoteProducts = emptyList()
            advance(25.hours)
            engine.drain(pull = true)
            assertEquals(1, db.products().getAll().size)

            // Catégories reçues, aucun produit publié : cache vidé.
            gateway.remoteCategories = listOf(category)
            advance(25.hours)
            engine.drain(pull = true)
            assertTrue(db.products().getAll().isEmpty())
        }

    /**
     * #47 : après un catalogue complet, la descente du lendemain ne lit que les produits publiés depuis, et ne retire
     * rien. Le catalogue complet revient une fois par semaine.
     */
    @Test
    fun theCatalogDownloadsOnlyNewlyPublishedProductsUntilTheWeeklyFullRefresh() =
        runBlocking {
            val start = now
            gateway.remoteCategories = listOf(CategoryRow(7, "dairy", "Crèmerie", 1))
            val old = RemoteProduct(Uuid.random(), "Lait", "lait", "dairy", null, start, publishedAt = start)
            gateway.remoteProducts = listOf(old)
            engine.drain(pull = true)
            assertEquals(1, gateway.callsOf("fetchProducts").size)
            assertEquals(start, cursors.catalogPublished)

            // Le lendemain : un produit publié depuis ; l'ancien, absent de la réponse, reste dans le cache.
            val fresh =
                RemoteProduct(Uuid.random(), "Kéfir", "kefir", "dairy", null, start, publishedAt = start + 1.hours)
            gateway.remoteProducts = listOf(fresh)
            advance(25.hours)
            engine.drain(pull = true)
            assertEquals(listOf("fetchProductsSince:$start"), gateway.callsOf("fetchProductsSince"))
            assertEquals(2, db.products().getAll().size)
            assertEquals(start + 1.hours, cursors.catalogPublished)

            // Une semaine après le catalogue complet, il est relu en entier : le produit absent quitte le cache.
            repeat(6) {
                advance(25.hours)
                engine.drain(pull = true)
            }
            assertEquals(2, gateway.callsOf("fetchProducts").size)
            assertEquals(listOf(fresh.id.toString()), db.products().getAll().map { it.id })
        }

    /**
     * #138 : la descente incrémentale retire du cache les produits dépubliés depuis son curseur, avec une heure de
     * recouvrement, puis avance ce curseur. L'article qui porte l'id d'un produit retiré ne change pas.
     */
    @Test
    fun anIncrementalCatalogPullDropsUnpublishedProductsAndLeavesTheirItemsIntact() =
        runBlocking {
            val start = now
            gateway.remoteCategories = listOf(CategoryRow(7, "dairy", "Crèmerie", 1))
            val milk = RemoteProduct(Uuid.random(), "Lait", "lait", "dairy", null, start, publishedAt = start)
            val kefir = RemoteProduct(Uuid.random(), "Kéfir", "kefir", "dairy", null, start, publishedAt = start)
            val butter = RemoteProduct(Uuid.random(), "Beurre", "beurre", "dairy", null, start, publishedAt = start)
            gateway.remoteProducts = listOf(milk, kefir, butter)
            val list = repository.createList("Courses", now)
            val added = repository.addItem(list.id, "Lait", "lait", null, milk.id.toString(), "dairy", now)
            engine.drain(pull = true)
            val item = db.items().get(added.id)
            assertEquals(milk.id.toString(), item?.productId)
            assertEquals(3, db.products().getAll().size)

            // Le lendemain, le lait est dépublié, donc illisible (RLS). Sans curseur : toutes les dépublications.
            val milkUnpublished = start + 2.hours
            gateway.remoteProducts = listOf(kefir, butter)
            gateway.remoteUnpublished = listOf(RemoteUnpublishedProduct(milk.id, milkUnpublished))
            advance(25.hours)
            engine.drain(pull = true)
            assertEquals(listOf("fetchUnpublishedProducts"), gateway.callsOf("fetchUnpublishedProducts"))
            assertEquals(
                setOf(kefir.id.toString(), butter.id.toString()),
                db
                    .products()
                    .getAll()
                    .map { it.id }
                    .toSet(),
            )
            assertEquals(milkUnpublished, cursors.catalogUnpublished)
            // L'article garde son produit, valide côté serveur, et rien ne repart.
            assertEquals(item, db.items().get(added.id))
            assertTrue(entries().isEmpty())

            // Dépublication validée en retard, datée d'avant le curseur mais dans l'heure de recouvrement : retirée
            // aussi. Le curseur ne recule pas.
            gateway.remoteProducts = listOf(butter)
            gateway.remoteUnpublished =
                listOf(
                    RemoteUnpublishedProduct(milk.id, milkUnpublished),
                    RemoteUnpublishedProduct(kefir.id, milkUnpublished - 30.minutes),
                )
            advance(25.hours)
            engine.drain(pull = true)
            assertEquals(
                "fetchUnpublishedProducts:$milkUnpublished",
                gateway.callsOf("fetchUnpublishedProducts").last(),
            )
            assertEquals(listOf(butter.id.toString()), db.products().getAll().map { it.id })
            assertEquals(milkUnpublished, cursors.catalogUnpublished)
            assertEquals(item, db.items().get(added.id))
        }

    /** #138 : le catalogue complet exclut déjà les produits dépubliés : il ne lit pas les dépublications. */
    @Test
    fun aFullCatalogPullNeitherReadsUnpublishedProductsNorMovesTheirCursor() =
        runBlocking {
            val start = now
            gateway.remoteCategories = listOf(CategoryRow(7, "dairy", "Crèmerie", 1))
            gateway.remoteProducts =
                listOf(RemoteProduct(Uuid.random(), "Lait", "lait", "dairy", null, start, publishedAt = start))
            gateway.remoteUnpublished = listOf(RemoteUnpublishedProduct(Uuid.random(), start + 1.hours))

            // Premier passage : complet.
            engine.drain(pull = true)
            assertEquals(1, gateway.callsOf("fetchProducts").size)
            assertTrue(gateway.callsOf("fetchUnpublishedProducts").isEmpty())
            assertNull(cursors.catalogUnpublished)

            // Une semaine plus tard : complet encore, curseur des dépublications laissé tel quel.
            cursors.catalogUnpublished = start
            advance(8.days)
            engine.drain(pull = true)
            assertEquals(2, gateway.callsOf("fetchProducts").size)
            assertTrue(gateway.callsOf("fetchUnpublishedProducts").isEmpty())
            assertEquals(start, cursors.catalogUnpublished)
        }

    /** #138 : un changement de compte e-mail purge l'appareil, curseur des dépublications compris. */
    @Test
    fun anAccountSwitchPurgeForgetsTheUnpublishedCursor() =
        runBlocking {
            val start = now
            gateway.remoteCategories = listOf(CategoryRow(7, "dairy", "Crèmerie", 1))
            gateway.remoteProducts =
                listOf(RemoteProduct(Uuid.random(), "Lait", "lait", "dairy", null, start, publishedAt = start))
            gateway.remoteUnpublished = listOf(RemoteUnpublishedProduct(Uuid.random(), start + 1.hours))
            engine.drain(pull = true)
            advance(25.hours)
            engine.drain(pull = true)
            assertEquals(start + 1.hours, cursors.catalogUnpublished)

            LocalDataPurge(db, cursors).run()

            assertNull(cursors.catalogUnpublished)
            assertNull(cursors.catalogPublished)
            // Le catalogue repart en entier, puis les dépublications sont toutes relues.
            engine.drain(pull = true)
            assertEquals(1, gateway.callsOf("fetchUnpublishedProducts").size)
            advance(25.hours)
            engine.drain(pull = true)
            assertEquals(List(2) { "fetchUnpublishedProducts" }, gateway.callsOf("fetchUnpublishedProducts"))
            assertEquals(start + 1.hours, cursors.catalogUnpublished)
        }

    @Test
    fun noPullWithoutARequestOrASend() =
        runBlocking {
            engine.drain()
            assertTrue(gateway.callsOf("fetchLists").isEmpty())
            repository.createList("Courses", now)
            engine.drain()
            // Un envoi déclenche une descente (aucune encore faite).
            assertEquals(1, gateway.callsOf("fetchLists").size)
            repository.createList("Autre", now)
            engine.drain()
            // Moins d'une minute après : pas de nouvelle descente.
            assertEquals(1, gateway.callsOf("fetchLists").size)
            advance(61.seconds)
            repository.createList("Encore", now)
            engine.drain()
            assertEquals(2, gateway.callsOf("fetchLists").size)
        }

    @Test
    fun aFailedPullIsRetriedOnceAMinuteWithoutHoldingTheSend() =
        runBlocking {
            gateway.failNext("fetchLists", RemoteError.Network())
            val wake = engine.drain(pull = true)
            assertEquals(now + 60.seconds, wake)
            engine.drain()
            assertEquals(1, gateway.callsOf("fetchLists").size)
            advance(61.seconds)
            engine.drain()
            assertEquals(2, gateway.callsOf("fetchLists").size)
        }

    // endregion

    // region Réseau et session

    @Test
    fun offlineNothingLeavesAndThePullStaysDue() =
        runBlocking {
            repository.createList("Courses", now)
            online = false
            assertNull(engine.drain(pull = true))
            assertTrue(gateway.calls.isEmpty())

            online = true
            engine.drain()
            assertEquals(1, gateway.callsOf("saveList").size)
            assertEquals(1, gateway.callsOf("fetchLists").size)
        }

    @Test
    fun aLostSessionWaitsForAForcedPassToRestoreIt() =
        runBlocking {
            repository.createList("Courses", now)
            gateway.failNext("currentAccountId", RemoteError.Unauthorized())

            assertNull(engine.drain())
            assertTrue(engine.isWaitingForSession)
            assertEquals(1, entries().size)

            // Sans passe forcée, rien ne tente de retrouver la session.
            engine.drain()
            assertTrue(gateway.callsOf("ensureSession").isEmpty())

            engine.drain(pull = true)
            assertEquals(1, gateway.callsOf("ensureSession").size)
            assertFalse(engine.isWaitingForSession)
            assertTrue(entries().isEmpty())
        }

    // endregion

    // region Compte

    @Test
    fun aChangedAccountReidentifiesTheDataAndAcknowledgesIt() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val item = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            engine.drain()
            val oldAccount = gateway.account
            val newAccount = Uuid.random()
            gateway.account = newAccount
            gateway.failNext("currentAccountId", RemoteError.AccountChanged())
            val remaps = mutableListOf<Map<String, String>>()
            val collector =
                launch(start = CoroutineStart.UNDISPATCHED) {
                    engine.remaps.collect {
                        remaps +=
                            it.identifiers
                    }
                }
            cursors.accountId = oldAccount

            engine.drain()
            yield()
            collector.cancel()

            assertEquals(listOf(newAccount), gateway.acknowledged)
            assertEquals(newAccount, cursors.accountId)
            val newList = db.lists().getAll().single()
            assertTrue(newList.id != list.id)
            assertTrue(
                db
                    .items()
                    .getAll()
                    .single()
                    .id != item.id,
            )
            assertEquals(newList.id, remaps.last()[list.id])
            // Tout est reparti vers le nouveau compte.
            assertEquals(2, gateway.callsOf("saveList").size)
            assertTrue(entries().isEmpty())
        }

    @Test
    fun anInterruptionBetweenTheRekeyAndTheAcknowledgementReplaysTheRecovery() =
        runBlocking {
            modifiedList()
            cursors.accountId = Uuid.random()
            gateway.beforeCall = { if (it == "acknowledgeAccount") throw CancellationException("annulé") }

            val interrupted = runCatching { engine.drain() }.exceptionOrNull()
            assertTrue(interrupted is CancellationException)
            assertTrue(gateway.acknowledged.isEmpty())
            assertTrue(gateway.callsOf("saveList").isEmpty())

            gateway.beforeCall = {}
            engine.drain()
            // Le compte n'est acquitté qu'une fois les données réidentifiées, jamais avant : rien n'est parti avant.
            assertEquals(listOf(gateway.account), gateway.acknowledged)
            assertEquals(1, gateway.callsOf("saveList").size)
            assertEquals(2, gateway.callsOf("sessionAccountId").size)
        }

    @Test
    fun aLockedSecureStorageIsADelayAndNeverTouchesTheData() =
        runBlocking {
            val list = modifiedList()
            cursors.accountId = Uuid.random()
            gateway.failNext("sessionAccountId", RemoteError.SecureStorageLocked())

            val wake = engine.drain()

            assertEquals(now + 2.seconds, wake)
            assertEquals(
                list.id,
                db
                    .lists()
                    .getAll()
                    .single()
                    .id,
            )
            assertTrue(gateway.acknowledged.isEmpty())
            assertEquals(OutboxKind.UpsertList, entries().single().kind())
        }

    @Test
    fun aScreenOpenedAfterARekeyStillReceivesTheMappingAndRekeysChain() =
        runBlocking {
            val list = modifiedList()
            engine.drain()
            repeat(2) {
                gateway.account = Uuid.random()
                cursors.accountId = Uuid.random()
                engine.drain()
            }
            // Abonné tardif : tout l'historique, chaque ancien identifiant menant à l'identifiant courant.
            val latest = engine.remaps.first { it.identifiers.isNotEmpty() }.identifiers
            val current =
                db
                    .lists()
                    .getAll()
                    .single()
                    .id
            assertEquals(current, latest[list.id])
            assertEquals(2, latest.size)
        }

    // endregion

    // region Résolution des produits

    @Test
    fun aResolvedItemLeavesAgainWithItsProduct() =
        runBlocking {
            val list = repository.createList("Courses", now)
            val item = repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val product = Uuid.random()
            gateway.resolver = { rows ->
                rows.map { ResolvedProductRow("lait", product, "Lait", "dairy") }
            }

            engine.drain()

            assertEquals(product.toString(), db.items().get(item.id)?.productId)
            assertEquals(
                product.toString(),
                gateway.savedItems
                    .single { it.id.toString() == item.id }
                    .productId
                    .toString(),
            )
            assertEquals("Lait", db.products().get(product.toString())?.name)
            assertEquals("dairy", db.items().get(item.id)?.categoryId)
        }

    @Test
    fun aMissingFunctionDelaysTheResolutionFiveMinutesWithoutHoldingTheQueue() =
        runBlocking {
            repository
                .createList(
                    "Courses",
                    now,
                ).also { repository.addItem(it.id, "lait", "lait", null, null, "dairy", now) }
            gateway.failNext("resolveProducts", RemoteError.Rejected(RemoteError.FUNCTION_NOT_FOUND_CODE), times = 10)

            engine.drain()
            assertEquals(1, gateway.callsOf("resolveProducts").size)
            assertEquals(1, gateway.callsOf("saveList").size)
            assertEquals(1, gateway.callsOf("insertItem").size)
            assertTrue(entries().isEmpty())

            advance(4.minutes)
            engine.drain(pull = true)
            assertEquals(1, gateway.callsOf("resolveProducts").size)
            advance(2.minutes)
            engine.drain(pull = true)
            assertEquals(2, gateway.callsOf("resolveProducts").size)
        }

    /**
     * #47 : un article sans produit en retour n'est pas renvoyé avant un jour, même par un nouveau moteur (redémarrage
     * de l'app) : les essais sont gardés avec les curseurs.
     */
    @Test
    fun aLabelWithoutProductWaitsADayEvenAfterARestart() =
        runBlocking {
            val list = repository.createList("Courses", now)
            repository.addItem(list.id, "Graines de chia", "graine chia", null, null, "bio", now)
            engine.drain()
            assertEquals(1, gateway.callsOf("resolveProducts").size)
            assertEquals(1, cursors.resolutionAttempts.size)

            val restarted = SyncEngine(gateway, db, cursors, classify, dependencies)
            restarted.drain(pull = true)
            assertEquals(1, gateway.callsOf("resolveProducts").size)

            advance(24.hours)
            SyncEngine(gateway, db, cursors, classify, dependencies).drain(pull = true)
            assertEquals(2, gateway.callsOf("resolveProducts").size)
        }

    @Test
    fun resolutionDelaysAreOneMinuteOnNetworkAndOneHourOnRefusal() =
        runBlocking {
            val list = repository.createList("Courses", now)
            repository.addItem(list.id, "lait", "lait", null, null, "dairy", now)

            gateway.failNext("resolveProducts", RemoteError.Network())
            engine.drain()
            assertEquals(1, gateway.callsOf("resolveProducts").size)
            advance(59.seconds)
            engine.drain(pull = true)
            assertEquals(1, gateway.callsOf("resolveProducts").size)
            advance(2.seconds)
            gateway.failNext("resolveProducts", RemoteError.Rejected("22023"))
            engine.drain(pull = true)
            assertEquals(2, gateway.callsOf("resolveProducts").size)
            advance(59.minutes)
            engine.drain(pull = true)
            assertEquals(2, gateway.callsOf("resolveProducts").size)
            advance(2.minutes)
            engine.drain(pull = true)
            assertEquals(3, gateway.callsOf("resolveProducts").size)
        }

    // endregion

    // region Horloge

    @Test
    fun aVisitDatedInTheFutureIsShiftedToTheServerClockWithoutAnAttempt() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val item = insertItem(list.id)
            val visit = visit(list.id)
            val skew = 2.hours
            val check = check(visit.id, item.id, at = now + skew)
            db.visits().upsert(visit.copy(startedAt = now + skew))
            db.checks().upsert(check)
            val queue = OutboxQueue(db.outbox())
            queue.enqueueCreation(visit.copy(startedAt = now + skew), list.id, now)
            queue.enqueueInsertion(check, now)
            gateway.serverDate = now
            gateway.failNext("createVisit", RemoteError.Constraint("23514"))

            engine.drain()

            assertTrue(entries().isEmpty())
            assertEquals(2, gateway.callsOf("createVisit").size)
            // La date locale n'a pas bougé : seule la charge utile a été corrigée.
            assertEquals(now + skew, db.checks().get(check.id)?.checkedAt)
            assertTrue(
                gateway.savedChecks
                    .single()
                    .single()
                    .checkedAt <= now,
            )
        }

    @Test
    fun anUnreadableSiblingDoesNotBlockTheClockCorrection() =
        runBlocking {
            val list = insertList(state = SyncState.SYNCED)
            val item = insertItem(list.id)
            val visit = visit(list.id)
            val skew = 2.hours
            val check = check(visit.id, item.id, at = now + skew)
            db.visits().upsert(visit.copy(startedAt = now + skew))
            db.checks().upsert(check)
            val queue = OutboxQueue(db.outbox())
            queue.enqueueCreation(visit.copy(startedAt = now + skew), list.id, now)
            queue.enqueueInsertion(check, now)
            // Clôture sœur dont la date ne se lit pas (#120) : la correction l'ignore, elle finira en `FAILED`.
            db.outbox().enqueue(
                "bad-close",
                OutboxKind.CloseVisit,
                visit.id,
                """{"visitId":"${visit.id}","endedAt":"pas-une-date"}""".encodeToByteArray(),
                now,
            )
            gateway.serverDate = now
            gateway.failNext("createVisit", RemoteError.Constraint("23514"))

            engine.drain()

            // La création et la coche partent corrigées ; seule la clôture illisible reste, en `FAILED`.
            assertEquals(2, gateway.callsOf("createVisit").size)
            assertTrue(
                gateway.savedChecks
                    .single()
                    .single()
                    .checkedAt <= now,
            )
            val left = entries().single()
            assertEquals("bad-close", left.id)
            assertEquals(SyncState.FAILED, left.syncState)
        }

    // endregion
}
