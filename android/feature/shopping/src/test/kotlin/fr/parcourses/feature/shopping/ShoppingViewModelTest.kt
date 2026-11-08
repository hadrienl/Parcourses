package fr.parcourses.feature.shopping

import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.database.entity.OutboxKind
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@Suppress("LargeClass")
class ShoppingViewModelTest : ShoppingTest() {
    private suspend fun groceries() =
        newList(
            Triple("lait", "dairy", null),
            Triple("pain", "bakery", null),
            Triple("pommes", "produce", null),
        )

    private suspend fun kinds() = db.outbox().pending().map { it.kind() }

    // region Ordre et rayons

    @Test
    fun withoutAGraphItemsAreGroupedByAisleInRankOrderWithTitles() =
        runTest(main) {
            val (listId, _) = groceries()
            val state = started(model(listId))

            assertTrue(state.isLoaded)
            assertTrue(state.groupsByAisle)
            assertEquals(listOf("produce", "bakery", "dairy"), state.sections.map { it.aisleId })
            assertEquals("Fruits et légumes", state.sections.first().title)
            assertEquals(listOf("pommes", "pain", "lait"), state.labels())
            assertEquals(RouteKnowledge.Unknown, state.knowledge)
            assertEquals("Courses", state.name)
            assertEquals("Carrefour", state.storeName)
        }

    @Test
    fun aLearnedGraphGivesOneContinuousThreadWithoutAisleTitles() =
        runTest(main) {
            val (listId, _) =
                newList(Triple("lait", "dairy", P3), Triple("pain", "bakery", P1), Triple("pommes", "produce", P2))
            cacheSnapshot(learnedPayload(P1, P2, P3))
            val state = started(model(listId))

            assertFalse(state.groupsByAisle)
            assertTrue(state.sections.isEmpty())
            assertEquals(RouteKnowledge.Learned(80), state.knowledge)
            assertEquals(listOf("pain", "pommes", "lait"), state.labels())
            // `listWasSorted` : le mode du début de visite.
            assertTrue(visits.openVisit()!!.listWasSorted)
        }

    @Test
    fun aWeakGraphIsStillLearningAndStaysGroupedByAisle() =
        runTest(main) {
            val (listId, _) = newList(Triple("lait", "dairy", P1), Triple("pain", "bakery", P2))
            cacheSnapshot(learnedPayload(P1, P2, confidenceQ = 300))
            val state = started(model(listId))

            assertEquals(RouteKnowledge.Learning(30), state.knowledge)
            assertTrue(state.groupsByAisle)
            assertFalse(visits.openVisit()!!.listWasSorted)
        }

    @Test
    fun theOrganicAisleIsUsedOnlyWhenTheStoreHasOne() =
        runTest(main) {
            val (listId, _) = newList(Triple("lait bio", "dairy", null), Triple("pain", "bakery", null))
            stores.upsertStore(storeId, "Biocoop", null, null, organicAisle = true)
            val state = started(model(listId))
            assertEquals(listOf("bakery", "bio"), state.sections.map { it.aisleId })
        }

    // endregion

    // region Coches et tri en direct

    @Test
    fun aCheckedRowKeepsItsPlaceThenMovesToTheBasketAfter600Milliseconds() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)

            model.toggle(state.row("pommes"))
            runCurrent()
            val checked = model.uiState.value
            assertEquals(listOf("pommes", "pain", "lait"), checked.labels())
            assertTrue(checked.toBuy.first().isChecked)
            assertTrue(checked.basket.isEmpty())
            assertEquals(2, checked.toBuyCount)

            after(599)
            assertTrue(
                model.uiState.value.basket
                    .isEmpty(),
            )
            after(2)
            val settled = model.uiState.value
            assertEquals(listOf("pain", "lait"), settled.labels())
            assertEquals(listOf("pommes"), settled.basket.map { it.label })
        }

    @Test
    fun aCheckWritesTheCheckTheItemAndKeepsTheVisitLocalUntilItLeaves() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            val state = started(model)
            val before = db.outbox().pending().size

            model.toggle(state.row("lait"))
            runCurrent()

            val visit = visits.openVisit()!!
            assertEquals(storeId, visit.storeId)
            assertEquals(1, visits.checks(visit.id).size)
            assertNotNull(db.items().get(items.first().id)?.checkedAt)
            assertTrue(db.outbox().pending().size > before)
            assertTrue(kinds().containsAll(listOf(OutboxKind.CreateVisit, OutboxKind.InsertChecks)))
            // Retenue le temps de l'annulation : la coche ne part pas pendant la bannière.
            assertTrue(db.outbox().due(clock()).none { it.kind() == OutboxKind.InsertChecks })
        }

    @Test
    fun aScrollSuspendsTheSortUntilItEnds() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pommes"))
            runCurrent()

            model.setScrolling(true)
            after(10_000)
            assertEquals(listOf("pommes", "pain", "lait"), model.uiState.value.labels())

            model.setScrolling(false)
            after(601)
            assertEquals(listOf("pain", "lait"), model.uiState.value.labels())
        }

    @Test
    fun onlyATypedEntrySuspendsTheSort() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)

            // Clavier ouvert sans texte : la liste ne reste pas figée.
            model.setEditing(true)
            model.toggle(state.row("pommes"))
            runCurrent()
            after(601)
            assertEquals(listOf("pain", "lait"), model.uiState.value.labels())

            model.input.setTextAndPlaceCursorAtEnd("2 yaourts")
            model.toggle(model.uiState.value.row("pain"))
            runCurrent()
            after(5_000)
            assertEquals(listOf("pain", "lait"), model.uiState.value.labels())
            assertTrue(
                model.uiState.value.toBuy
                    .first()
                    .isChecked,
            )

            model.input.setTextAndPlaceCursorAtEnd("")
            model.setEditing(true)
            after(601)
            assertEquals(listOf("lait"), model.uiState.value.labels())
        }

    @Test
    fun uncheckingABasketRowBringsItBack() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pommes"))
            runCurrent()
            after(601)

            model.toggle(model.uiState.value.row("pommes"))
            runCurrent()
            after(601)

            val back = model.uiState.value
            assertTrue(back.basket.isEmpty())
            assertEquals(listOf("pommes", "pain", "lait"), back.labels())
            assertTrue(visits.checks(visits.openVisit()!!.id).isEmpty())
        }

    @Test
    fun theSortOnlyRunsOnTheRowsStillToBuy() =
        runTest(main) {
            val (listId, _) =
                newList(Triple("lait", "dairy", P3), Triple("pain", "bakery", P1), Triple("pommes", "produce", P2))
            cacheSnapshot(learnedPayload(P1, P2, P3))
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pain"))
            runCurrent()
            after(601)
            // Le départ est le dernier produit coché : le fil continue à partir de lui.
            assertEquals(listOf("pommes", "lait"), model.uiState.value.labels())
        }

    // endregion

    // region Introuvable

    @Test
    fun notFoundIsLocalOnlyAndLeavesTheCheckedStateAlone() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            val state = started(model)
            val pending = db.outbox().pending().size
            val updatedAt = db.items().get(items.first().id)?.updatedAt

            model.markNotFound(state.row("lait"))
            runCurrent()

            val after = model.uiState.value
            assertEquals(listOf("lait"), after.notFound.map { it.label })
            assertFalse(after.labels().contains("lait"))
            assertNotNull(db.items().get(items.first().id)?.notFoundAt)
            assertNull(db.items().get(items.first().id)?.checkedAt)
            // Purement local : ni file d'envoi, ni updatedAt.
            assertEquals(pending, db.outbox().pending().size)
            assertEquals(updatedAt, db.items().get(items.first().id)?.updatedAt)
            assertEquals(ShoppingUndo.Kind.NotFound, after.undo?.kind)
            // Un article introuvable compte parmi ceux qu'il reste à décider.
            assertEquals(3, after.remainingCount)
        }

    @Test
    fun undoingNotFoundPutsTheRowBackWhereItWas() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.markNotFound(state.row("pain"))
            runCurrent()

            model.performUndo()
            runCurrent()

            val back = model.uiState.value
            assertEquals(listOf("pommes", "pain", "lait"), back.labels())
            assertTrue(back.notFound.isEmpty())
            assertNull(back.undo)
        }

    @Test
    fun aNotFoundRowCanBeRestored() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            val state = started(model)
            model.markNotFound(state.row("lait"))
            runCurrent()

            model.restore(model.uiState.value.row("lait"))
            runCurrent()
            after(601)

            assertTrue(
                model.uiState.value.notFound
                    .isEmpty(),
            )
            assertTrue(
                model.uiState.value
                    .labels()
                    .contains("lait"),
            )
            assertNull(db.items().get(items.first().id)?.notFoundAt)
        }

    // endregion

    // region Ajout en route

    @Test
    fun anAddedItemTakesItsEstimatedPlaceWithoutMovingTheOthers() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)

            model.input.setTextAndPlaceCursorAtEnd("2 baguettes")
            model.submit()
            runCurrent()

            val state = model.uiState.value
            // Rayon boulangerie : juste après les fruits, avant le pain, sans bouger les autres lignes.
            assertEquals(listOf("pommes", "baguettes", "pain", "lait"), state.labels())
            assertEquals("2", state.row("baguettes").quantity)
            assertEquals(state.row("baguettes").id, state.highlightedItemId)
            assertEquals("", model.input.text.toString())
            assertEquals(4, lists.items(listId).size)
            // Le repère disparaît seul.
            after(301)
            assertNull(model.uiState.value.highlightedItemId)
        }

    @Test
    fun anEmptyEntryAddsNothing() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)
            model.input.setTextAndPlaceCursorAtEnd("   ")
            model.submit()
            runCurrent()
            assertEquals(3, lists.items(listId).size)
        }

    @Test
    fun aDoubleSubmitAddsTheItemOnce() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)
            model.input.setTextAndPlaceCursorAtEnd("beurre")
            model.submit()
            model.submit()
            runCurrent()
            assertEquals(4, lists.items(listId).size)
        }

    // endregion

    // region Annulation

    @Test
    fun undoingACheckRemovesTheLocalCheckAndTheRowKeepsItsPlace() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pain"))
            runCurrent()
            assertEquals(
                ShoppingUndo.Kind.Check,
                model.uiState.value.undo
                    ?.kind,
            )
            assertEquals(
                "pain",
                model.uiState.value.undo
                    ?.label,
            )

            model.performUndo()
            runCurrent()

            val back = model.uiState.value
            assertEquals(listOf("pommes", "pain", "lait"), back.labels())
            assertTrue(back.toBuy.none { it.isChecked })
            assertNull(back.undo)
            assertTrue(visits.checks(visits.openVisit()!!.id).isEmpty())
            assertFalse(kinds().contains(OutboxKind.InsertChecks))
            assertFalse(kinds().contains(OutboxKind.CreateVisit))
            assertNull(db.items().get(items[1].id)?.checkedAt)
            // L'annulation n'est pas un nouveau trajet : rien ne se réordonne ensuite.
            after(5_000)
            assertEquals(listOf("pommes", "pain", "lait"), model.uiState.value.labels())
        }

    @Test
    fun theUndoBannerDisappearsAfterFourSeconds() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pain"))
            runCurrent()

            after(3_999)
            assertNotNull(model.uiState.value.undo)
            after(2)
            assertNull(model.uiState.value.undo)
            // Une coche non annulée à temps est partie du banc : la file la libère après la marge.
            after(1_000)
            assertTrue(db.outbox().due(clock()).any { it.kind() == OutboxKind.InsertChecks })
        }

    @Test
    fun aNewActionReplacesTheUndoOfThePreviousOne() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pain"))
            runCurrent()
            after(3_000)
            model.toggle(model.uiState.value.row("lait"))
            runCurrent()
            after(2_000)

            assertEquals(
                "lait",
                model.uiState.value.undo
                    ?.label,
            )
        }

    // endregion

    // region Annonces et changements extérieurs

    @Test
    fun anExternalChangeIsReloadedThenSortedAndAnnouncedPolitely() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            started(model)
            assertNull(model.uiState.value.reorder)

            // Venu d'un autre appareil : le lait change de rayon.
            db.items().upsert(db.items().get(items.first().id)!!.copy(categoryId = "produce"))
            runCurrent()
            after(601)

            val state = model.uiState.value
            assertEquals(listOf("lait", "pommes", "pain"), state.labels())
            assertEquals("lait", state.reorder?.next)
            val seq = state.reorder!!.seq
            model.announcementShown(seq + 1)
            assertNotNull(model.uiState.value.reorder)
            model.announcementShown(seq)
            assertNull(model.uiState.value.reorder)
        }

    @Test
    fun anInsertionAloneIsNotAnnouncedAsAReorder() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)

            lists.addItem(listId, "baguette", "baguette", null, null, "bakery", clock())
            runCurrent()
            after(601)

            assertEquals(listOf("pommes", "baguette", "pain", "lait"), model.uiState.value.labels())
            assertNull(model.uiState.value.reorder)
        }

    @Test
    fun ourOwnWritesAreNotTakenForExternalChanges() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pain"))
            runCurrent()
            model.performUndo()
            runCurrent()
            after(2_000)
            assertEquals(listOf("pommes", "pain", "lait"), model.uiState.value.labels())
            assertNull(model.uiState.value.reorder)
        }

    // endregion

    // region Reprise de compte et erreurs

    @Test
    fun anAccountRecoveryRenamesTheRowsAndTheUndo() =
        runTest(main) {
            val (listId, _) = groceries()
            val remaps = MutableSharedFlow<IdentifierRemap>(extraBufferCapacity = 1)
            val model = model(listId, remaps = remaps)
            val state = started(model)
            val milk = state.row("lait")
            model.toggle(milk)
            runCurrent()

            remaps.tryEmit(IdentifierRemap(mapOf(milk.id to "nouveau")))
            runCurrent()

            val renamed = model.uiState.value
            assertEquals("nouveau", renamed.row("lait").id)
            assertEquals("nouveau", renamed.undo?.itemId)
        }

    @Test
    fun aFailedWriteIsShownAndCanBeDismissed() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            lists.deleteList(listId, clock())

            model.markNotFound(state.row("lait"))
            runCurrent()

            assertNotNull(model.uiState.value.errorMessage)
            model.dismissError()
            assertNull(model.uiState.value.errorMessage)
        }

    // endregion

    // region Revue de la PR #56

    @Test
    fun aDoubleCheckEventChecksOnce() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            val stale = started(model).row("lait")

            // Deux événements sur la même ligne, lue avant la première coche (double appui, balayage puis appui).
            model.toggle(stale)
            model.toggle(stale)
            runCurrent()

            val visit = visits.openVisit()!!
            assertEquals(1, visits.checks(visit.id).size)
            assertEquals(1, kinds().count { it == OutboxKind.InsertChecks })
            assertNotNull(db.items().get(items.first().id)?.checkedAt)
            assertNull(model.uiState.value.errorMessage)
        }

    @Test
    fun aHorizontalSwipeSuspendsTheSort() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pommes"))
            runCurrent()

            model.setSwiping(true)
            after(5_000)
            assertEquals(listOf("pommes", "pain", "lait"), model.uiState.value.labels())
            model.setSwiping(false)
            after(601)
            assertEquals(listOf("pain", "lait"), model.uiState.value.labels())
        }

    @Test
    fun theUndoWindowAndTheSendHoldShareTheirOrigin() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            // Accessibilité : délai d'action allongé à 10 s.
            model.setUndoDuration(kotlin.time.Duration.parse("10s"))
            val checkedAt = clock()
            model.toggle(state.row("pain"))
            runCurrent()

            val held = db.outbox().pending().first { it.kind() == OutboxKind.InsertChecks }
            // La coche est retenue jusqu'à la fin de la bannière, plus la marge.
            assertEquals(checkedAt + kotlin.time.Duration.parse("11s"), held.nextAttemptAt)
            after(9_999)
            assertNotNull(model.uiState.value.undo)
            after(2)
            assertNull(model.uiState.value.undo)
        }

    @Test
    fun aShorterUndoThanTheDefaultIsNotAccepted() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.setUndoDuration(kotlin.time.Duration.parse("1s"))
            model.toggle(state.row("pain"))
            runCurrent()
            after(3_000)
            assertNotNull(model.uiState.value.undo)
        }

    @Test
    fun leavingTheScreenRightAfterACheckDoesNotLoseIt() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            val state = started(model)

            model.toggle(state.row("lait"))
            // Retour avant que l'écriture ne soit faite : le modèle est détruit.
            viewModels.clear()
            runCurrent()

            assertNotNull(db.items().get(items.first().id)?.checkedAt)
            assertEquals(1, db.checks().getAll().size)
        }

    @Test
    fun aChangeOfSyncStateAloneIsNotAnExternalChange() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            started(model)
            val before = model.externalReloads

            db.items().setSyncState(items.first().id, fr.parcourses.core.database.entity.SyncState.SYNCED)
            runCurrent()
            assertEquals(before, model.externalReloads)

            db.items().upsert(db.items().get(items.first().id)!!.copy(label = "lait entier"))
            runCurrent()
            assertEquals(before + 1, model.externalReloads)
        }

    // endregion
}
