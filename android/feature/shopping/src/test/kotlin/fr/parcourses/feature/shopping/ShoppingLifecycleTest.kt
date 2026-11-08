package fr.parcourses.feature.shopping

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.network.dto.GraphSnapshotResponse
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.minutes

@RunWith(AndroidJUnit4::class)
class ShoppingLifecycleTest : ShoppingTest() {
    private suspend fun groceries() =
        newList(
            Triple("lait", "dairy", null),
            Triple("pain", "bakery", null),
            Triple("pommes", "produce", null),
        )

    // region Sans magasin

    @Test
    fun withoutAStoreThereIsNoVisitAndNoSnapshot() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId, store = null)
            val state = started(model)

            assertEquals(RouteKnowledge.NoStore, state.knowledge)
            assertEquals(null, state.storeName)
            assertEquals(0, gateway!!.snapshotCalls)

            model.toggle(state.row("lait"))
            runCurrent()

            assertTrue(db.visits().getAll().isEmpty())
            assertTrue(db.checks().getAll().isEmpty())
            assertNotNull(db.items().get(items.first().id)?.checkedAt)
            // Le coché part tout de même avec l'article.
            assertTrue(db.outbox().pending().any { it.kind() == OutboxKind.UpsertItem })

            model.finish(keepRemaining = true)
            runCurrent()
            assertNull(
                model.uiState.value.summary
                    ?.visitId,
            )
            assertEquals(
                1,
                model.uiState.value.summary
                    ?.checkedCount,
            )
        }

    // endregion

    // region Instantané du graphe

    @Test
    fun theServerSnapshotIsCachedAndUsedAtTheStart() =
        runTest(main) {
            val (listId, _) = newList(Triple("lait", "dairy", P2), Triple("pain", "bakery", P1))
            gateway!!.snapshot = { GraphSnapshotResponse.Payload(learnedPayload(P1, P2)) }
            val state = started(model(listId))

            assertEquals(RouteKnowledge.Learned(80), state.knowledge)
            assertEquals(listOf("pain", "lait"), state.labels())
            val cached = graphs.snapshot(storeId)!!
            assertEquals(5L, cached.snapshotVersion)
            assertEquals(800L, cached.confidenceQ)

            // La version connue est redemandée : le serveur répond « inchangé » et le cache suffit.
            gateway!!.snapshot = { GraphSnapshotResponse.Unchanged }
            started(model(listId))
            assertEquals(listOf<Long?>(null, 5L), gateway!!.knownVersions)
        }

    @Test
    fun anUnreadableSnapshotFallsBackToTheGenericOrder() =
        runTest(main) {
            val (listId, _) = newList(Triple("lait", "dairy", P2), Triple("pain", "bakery", P1))
            gateway!!.snapshot = { GraphSnapshotResponse.Payload("""{"format_version":9}""") }
            val state = started(model(listId))
            assertEquals(RouteKnowledge.Unknown, state.knowledge)
            assertNull(graphs.snapshot(storeId))
        }

    @Test
    fun theCacheAloneIsEnoughWithoutNetwork() =
        runTest(main) {
            val (listId, _) = newList(Triple("lait", "dairy", P2), Triple("pain", "bakery", P1))
            cacheSnapshot(learnedPayload(P1, P2))
            gateway = null
            val state = started(model(listId))
            assertEquals(RouteKnowledge.Learned(80), state.knowledge)
        }

    @Test
    fun aSlowServerIsWaitedForThreeSecondsThenAppliedOnTheNextCheck() =
        runTest(main) {
            val (listId, _) =
                newList(Triple("lait", "dairy", P2), Triple("pain", "bakery", P1), Triple("pommes", "produce", P3))
            val answer = hanging()
            gateway!!.snapshot = { answer.await() }
            val model = model(listId)
            model.start()
            runCurrent()

            after(2_999)
            assertFalse(model.uiState.value.isLoaded)
            after(2)
            val early = model.uiState.value
            assertTrue(early.isLoaded)
            assertEquals(RouteKnowledge.Unknown, early.knowledge)

            // La réponse arrive pendant la visite : la liste ne bouge pas d'elle-même.
            answer.complete(GraphSnapshotResponse.Payload(learnedPayload(P1, P2, P3)))
            runCurrent()
            after(5_000)
            assertEquals(RouteKnowledge.Unknown, model.uiState.value.knowledge)
            assertEquals(listOf("pommes", "pain", "lait"), model.uiState.value.labels())
            assertNotNull(graphs.snapshot(storeId))

            // ... et ne s'applique qu'à la coche suivante.
            model.toggle(model.uiState.value.row("pommes"))
            runCurrent()
            assertEquals(RouteKnowledge.Learned(80), model.uiState.value.knowledge)
        }

    @Test
    fun theOrganicAisleOfTheServerIsAdoptedAtTheStartAndCached() =
        runTest(main) {
            val (listId, _) = newList(Triple("lait bio", "dairy", null), Triple("pain", "bakery", null))
            gateway!!.organic = { true }
            val state = started(model(listId))
            assertEquals(listOf("bakery", "bio"), state.sections.map { it.aisleId })
            assertTrue(stores.store(storeId)!!.organicAisle)
        }

    // endregion

    // region Fin de visite

    @Test
    fun finishingKeepingTheRestClearsNotFoundAndClosesTheVisit() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pommes"))
            runCurrent()
            model.markNotFound(model.uiState.value.row("lait"))
            runCurrent()
            val visit = visits.openVisit()!!

            model.finish(keepRemaining = true)
            runCurrent()

            val summary = model.uiState.value.summary!!
            assertEquals(1, summary.checkedCount)
            assertEquals(1, summary.minutes)
            assertEquals("Carrefour", summary.storeName)
            assertEquals(RouteKnowledge.Unknown, summary.knowledge)
            assertEquals(visit.id, summary.visitId)
            assertNotNull(visits.visit(visit.id)?.endedAt)
            assertNull(db.items().get(items.first().id)?.notFoundAt)
            assertEquals(3, lists.items(listId).size)
            assertTrue(db.outbox().pending().any { it.kind() == OutboxKind.CloseVisit })
            assertNull(visits.openVisit())
        }

    @Test
    fun finishingDroppingTheRestDeletesTheRemainingItems() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pommes"))
            runCurrent()
            model.markNotFound(model.uiState.value.row("lait"))
            runCurrent()

            model.finish(keepRemaining = false)
            runCurrent()

            assertEquals(listOf("pommes"), lists.items(listId).map { it.label })
            assertNotNull(model.uiState.value.summary)
        }

    @Test
    fun finishingWithoutAnyCheckDeletesTheVisit() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)
            assertNotNull(visits.openVisit())

            model.finish(keepRemaining = true)
            runCurrent()

            assertTrue(db.visits().getAll().isEmpty())
            assertEquals(
                0,
                model.uiState.value.summary
                    ?.checkedCount,
            )
            assertFalse(db.outbox().pending().any { it.kind() == OutboxKind.CreateVisit })
        }

    @Test
    fun everythingCheckedIsReported() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)
            assertFalse(model.uiState.value.isEverythingChecked)
            listOf("lait", "pain", "pommes").forEach {
                model.toggle(model.uiState.value.row(it))
                runCurrent()
                after(601)
            }
            assertTrue(model.uiState.value.isEverythingChecked)
            assertEquals(0, model.uiState.value.remainingCount)
        }

    @Test
    fun theSummaryCountsMinutesFromTheStart() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pommes"))
            runCurrent()
            offset = 17.minutes + offset
            model.finish(keepRemaining = true)
            runCurrent()
            assertEquals(
                17,
                model.uiState.value.summary
                    ?.minutes,
            )
        }

    // endregion

    // region Expiration

    @Test
    fun fortyFiveMinutesWithoutACheckEndTheVisitAtTheLastCheck() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pommes"))
            runCurrent()
            val lastCheck = visits.checks(visits.openVisit()!!.id).last().checkedAt

            offset += 44.minutes
            model.foregrounded()
            runCurrent()
            assertFalse(model.uiState.value.expired)

            offset += 2.minutes
            model.foregrounded()
            runCurrent()

            val expired = model.uiState.value
            assertTrue(expired.expired)
            assertNull(expired.summary)
            assertNull(expired.undo)
            // La date de fin est celle de la dernière coche, pas celle du retour.
            assertEquals(
                lastCheck,
                visits
                    .visit(
                        db
                            .visits()
                            .getAll()
                            .single()
                            .id,
                    )?.endedAt,
            )
            assertNull(visits.openVisit())

            model.finish(keepRemaining = true)
            runCurrent()
            assertEquals(
                1,
                model.uiState.value.summary
                    ?.minutes,
            )
        }

    @Test
    fun anExpiredVisitWithNothingLeftEndsByItself() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)
            listOf("lait", "pain", "pommes").forEach {
                model.toggle(model.uiState.value.row(it))
                runCurrent()
            }

            offset += 50.minutes
            model.foregrounded()
            runCurrent()

            assertTrue(model.uiState.value.expired)
            assertEquals(
                3,
                model.uiState.value.summary
                    ?.checkedCount,
            )
        }

    @Test
    fun anExpiredVisitWithoutChecksIsDeleted() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)
            offset += 46.minutes
            model.foregrounded()
            runCurrent()
            assertTrue(model.uiState.value.expired)
            assertTrue(db.visits().getAll().isEmpty())
        }

    @Test
    fun reopeningAStaleVisitClosesItAtItsLastCheckAndStartsAFreshOne() =
        runTest(main) {
            val (listId, _) = groceries()
            val first = model(listId)
            val state = started(first)
            first.toggle(state.row("lait"))
            runCurrent()
            val old = visits.openVisit()!!
            val lastCheck = visits.checks(old.id).last().checkedAt

            offset += 60.minutes
            val reopened = model(listId)
            started(reopened)

            assertFalse(reopened.uiState.value.expired)
            assertEquals(lastCheck, visits.visit(old.id)?.endedAt)
            val fresh = visits.openVisit()!!
            assertTrue(fresh.id != old.id)
            assertEquals(clock(), fresh.startedAt)
        }

    @Test
    fun aStaleVisitLeavesNoNotFoundToTheNextOne() =
        runTest(main) {
            // #54, M3 : visite quittée par Retour avec un introuvable, puis rouverte une heure plus tard.
            val (listId, items) = groceries()
            val first = model(listId)
            val state = started(first)
            first.toggle(state.row("pommes"))
            runCurrent()
            first.markNotFound(first.uiState.value.row("lait"))
            runCurrent()
            assertEquals(
                listOf("lait"),
                first.uiState.value.notFound
                    .map { it.label },
            )

            offset += 60.minutes
            val reopened = model(listId)
            val fresh = started(reopened)

            assertTrue(fresh.notFound.isEmpty())
            assertTrue("lait" in fresh.toBuy.map { it.label })
            assertNull(db.items().get(items.first().id)?.notFoundAt)
            // Déjà juste au premier affichage : aucun rechargement « venu d'ailleurs » ne rattrape la liste.
            assertEquals(0, reopened.externalReloads)
        }

    // endregion

    // region Reprise

    @Test
    fun reopeningTheSameListAndStoreResumesTheOpenVisit() =
        runTest(main) {
            val (listId, _) = groceries()
            val first = model(listId)
            val state = started(first)
            first.toggle(state.row("lait"))
            runCurrent()

            val second = model(listId)
            started(second)

            assertEquals(1, db.visits().getAll().size)
            assertEquals(1, visits.checks(visits.openVisit()!!.id).size)
            assertEquals(
                listOf("lait"),
                second.uiState.value.basket
                    .map { it.label },
            )
        }

    @Test
    fun aResumedVisitKeepsItsStartForTheSortAndTheSummary() =
        runTest(main) {
            val (listId, _) =
                newList(Triple("lait", "dairy", P3), Triple("pain", "bakery", P1), Triple("pommes", "produce", P2))
            cacheSnapshot(learnedPayload(P1, P2, P3))
            val first = model(listId)
            val state = started(first)
            first.toggle(state.row("pain"))
            runCurrent()

            // Mort du processus puis retour dix minutes plus tard : la visite reprend avec son début d'origine.
            offset += 10.minutes
            val resumed = model(listId)
            val again = started(resumed)
            // Le départ du tri est le dernier produit coché depuis le début de la visite : le fil continue de là.
            assertEquals(listOf("pommes", "lait"), again.labels())

            resumed.finish(keepRemaining = true)
            runCurrent()
            assertEquals(
                10,
                resumed.uiState.value.summary
                    ?.minutes,
            )
            assertEquals(
                1,
                resumed.uiState.value.summary
                    ?.checkedCount,
            )
        }

    @Test
    fun startingTwiceOpensOneVisit() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            model.start()
            model.start()
            runCurrent()
            assertEquals(1, db.visits().getAll().size)
            assertEquals(1, gateway!!.snapshotCalls)
        }

    // endregion
}
