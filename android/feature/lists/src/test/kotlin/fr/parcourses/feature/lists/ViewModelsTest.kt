package fr.parcourses.feature.lists

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.repository.ListRepository
import fr.parcourses.core.data.repository.RoomCategoryRepository
import fr.parcourses.core.data.repository.RoomProductRepository
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.data.sync.SyncStore
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.ProductEntity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

@RunWith(AndroidJUnit4::class)
class ViewModelsTest : ListsTest() {
    // region Écran Listes

    @Test
    fun createRenameDeleteAndCounts() =
        runBlocking {
            val model = listsModel()
            assertFalse(model.uiState.value.isLoaded)
            assertTrue(
                model.uiState
                    .await { it.isLoaded }
                    .lists
                    .isEmpty(),
            )
            assertFalse(ListsViewModel.isValid("  "))

            var created: String? = null
            model.create("   ") { created = it }
            model.create("  Semaine ") { created = it }
            val state = model.uiState.await { it.lists.isNotEmpty() }
            assertEquals(listOf("Semaine"), state.lists.map { it.name })
            val id = state.lists.single().id
            assertTrue(created == null || created == id)

            lists.addItem(id, "lait", "lait", null, null, "dairy", clock)
            val bread = lists.addItem(id, "pain", "pain", null, null, "bakery", clock)
            assertEquals(
                2,
                model.uiState
                    .await { it.lists.firstOrNull()?.remaining == 2 }
                    .lists
                    .single()
                    .remaining,
            )
            lists.setChecked(bread.id, clock, clock)
            assertEquals(
                1,
                model.uiState
                    .await { it.lists.firstOrNull()?.remaining == 1 }
                    .lists
                    .single()
                    .remaining,
            )

            model.rename(id, " Week-end ")
            assertEquals(
                "Week-end",
                model.uiState
                    .await { it.lists.firstOrNull()?.name == "Week-end" }
                    .lists
                    .single()
                    .name,
            )
            model.rename(id, "  ")
            assertEquals(
                "Week-end",
                model.uiState.value.lists
                    .single()
                    .name,
            )

            model.delete(id)
            assertTrue(model.uiState.await { it.lists.isEmpty() }.errorDetail == null)
        }

    @Test
    fun aWriteFailureIsReportedThenAcknowledged() =
        runBlocking {
            val model = listsModel()
            model.rename("inconnue", "Nom")
            assertEquals("Cet élément n'existe plus.", model.uiState.await { it.errorDetail != null }.errorDetail)
            model.dismissError()
            assertNull(model.uiState.await { it.errorDetail == null }.errorDetail)
        }

    @Test
    fun newestListComesFirst() =
        runBlocking {
            val old = lists.createList("Ancienne", clock)
            clock += 10.seconds
            val recent = lists.createList("Récente", clock)
            val state = listsModel().uiState.await { it.lists.size == 2 }
            assertEquals(listOf(recent.id, old.id), state.lists.map { it.id })
        }

    // endregion

    // region Écran Liste

    @Test
    fun quickEntryParsesClassifiesAndGroupsByRank() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val model = detailModel(id)
            assertTrue(model.uiState.await { it.isLoaded }.isEmpty)

            for ((index, text) in listOf("2 laits demi-écrémé", "pommes", "truc inconnu").withIndex()) {
                model.type(text)
                model.submit()
                // Un ajout à la fois : le suivant attend que le précédent soit écrit.
                model.uiState.await { s -> s.sections.sumOf { it.items.size } == index + 1 }
            }
            val state = model.uiState.await { s -> s.sections.sumOf { it.items.size } == 3 }

            assertEquals(listOf("produce", "dairy", "other"), state.sections.map { it.categoryId })
            assertEquals("Crèmerie, œufs, ultra-frais", state.sections[1].title)
            val milk = state.sections[1].items.single()
            assertEquals("laits demi-écrémé", milk.label)
            assertEquals("2", milk.quantity)
            assertEquals("laits demi-écrémé, 2", milk.accessibilityLabel)
            assertFalse(milk.isChecked)
            assertTrue(wakeUps >= 4)
        }

    @Test
    fun blankInputDoesNothing() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val model = detailModel(id)
            model.type("   ")
            model.submit()
            assertTrue(model.uiState.await { it.isLoaded }.isEmpty)
            assertEquals("   ", model.input.text.toString())
            assertTrue(lists.items(id).isEmpty())
        }

    @Test
    fun toggleAndDeleteArePersisted() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val item = lists.addItem(id, "lait", "lait", null, null, "dairy", clock)
            val model = detailModel(id)
            val row =
                model.uiState
                    .await { it.sections.isNotEmpty() }
                    .sections[0]
                    .items[0]

            model.toggle(row)
            val checked =
                model.uiState.await {
                    it.sections
                        .firstOrNull()
                        ?.items
                        ?.firstOrNull()
                        ?.isChecked == true
                }
            assertNotNull(lists.items(id).single().checkedAt)
            model.toggle(checked.sections[0].items[0])
            model.uiState.await {
                it.sections
                    .firstOrNull()
                    ?.items
                    ?.firstOrNull()
                    ?.isChecked == false
            }
            assertNull(lists.items(id).single().checkedAt)

            model.delete(row)
            assertTrue(model.uiState.await { it.isEmpty }.isEmpty)
            assertTrue(lists.items(id).isEmpty())
            // La suppression d'un article part au serveur.
            assertTrue(db.outbox().pending().any { it.kind() == OutboxKind.DeleteItem && it.entityId == item.id })
        }

    @Test
    fun sameEntryTwiceAddsTwoRows() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val model = detailModel(id)
            repeat(2) {
                model.type("lait")
                model.submit()
                model.uiState.await { s -> model.input.text.isEmpty() && s.isLoaded }
            }
            assertEquals(
                listOf(2),
                model.uiState
                    .await { s ->
                        s.sections.sumOf { it.items.size } == 2
                    }.sections
                    .map { it.items.size },
            )
            assertEquals(2, lists.items(id).size)
        }

    @Test
    fun anUnknownOrDeletedListIsMissing() =
        runBlocking {
            assertTrue(detailModel("inconnue").uiState.await { it.isLoaded }.isMissing)
            val id = lists.createList("Courses", clock).id
            assertFalse(detailModel(id).uiState.await { it.isLoaded }.isMissing)
            lists.deleteList(id, clock)
            assertTrue(detailModel(id).uiState.await { it.isLoaded }.isMissing)
        }

    @Test
    fun aFailedAddKeepsTheInputAndReportsTheError() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val model = detailModel(id)
            model.uiState.await { it.isLoaded }
            lists.deleteList(id, clock)
            model.type("lait")
            model.submit()
            val state = model.uiState.await { it.errorDetail != null }
            assertEquals("Cette liste a été supprimée.", state.errorDetail)
            assertEquals("lait", model.input.text.toString())
        }

    /** #69 : un produit qui n'est plus publié quitte le cache, et donc les suggestions ; l'historique reste. */
    @Test
    fun suggestionsDropAProductNoLongerPublished() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val other = lists.createList("Autre", clock).id
            lists.addItem(other, "tomates", "tomate", null, null, "produce", clock)
            val tofu = ProductEntity("11111111-1111-4111-8111-111111111111", "Tofu fumé", "tofu fume", "world-food")
            db.products().upsertAll(listOf(tofu))
            val model = detailModel(id)
            model.uiState.await { it.isLoaded }

            model.type("to")
            assertEquals(
                listOf("tomate", "tofu fume"),
                model.uiState
                    .await { it.suggestions.size == 2 }
                    .suggestions
                    .map { it.normalizedName },
            )
            SyncStore(db).replaceProducts(emptyList(), catalogReadable = true)
            assertEquals(
                listOf("tomate"),
                model.uiState
                    .await { it.suggestions.size == 1 }
                    .suggestions
                    .map { it.normalizedName },
            )
        }

    @Test
    fun suggestionsComeFromHistoryAndCatalog() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val other = lists.createList("Autre", clock).id
            lists.addItem(other, "tomates", "tomate", null, null, "produce", clock)
            lists.addItem(other, "pommes de terre", "pomme terre", null, null, "produce", clock)
            val tofu = ProductEntity("11111111-1111-4111-8111-111111111111", "Tofu fumé", "tofu fume", "world-food")
            db.products().upsertAll(listOf(tofu))
            val model = detailModel(id)
            assertTrue(
                model.uiState
                    .await { it.isLoaded }
                    .suggestions
                    .isEmpty(),
            )

            model.type("3 to")
            assertEquals(
                listOf("tomate", "tofu fume"),
                model.uiState
                    .await { it.suggestions.size == 2 }
                    .suggestions
                    .map { it.normalizedName },
            )
            model.type("terre")
            assertEquals(
                listOf("pomme terre"),
                model.uiState
                    .await {
                        it.suggestions.map { s ->
                            s.normalizedName
                        } == listOf("pomme terre")
                    }.suggestions
                    .map { it.normalizedName },
            )

            model.type("3 to")
            val tomato =
                model.uiState
                    .await { it.suggestions.size == 2 }
                    .suggestions
                    .first()
            model.add(tomato)
            model.uiState.await { s -> s.sections.sumOf { it.items.size } == 1 }
            assertTrue(model.input.text.isEmpty())
            val row = lists.items(id).single()
            // La quantité tapée est gardée avec la proposition.
            assertEquals("3", row.quantity)
            assertEquals("tomates", row.label)
            // Un article déjà à acheter n'est plus proposé.
            model.type("to")
            assertEquals(
                listOf("tofu fume"),
                model.uiState
                    .await {
                        it.suggestions.map { s -> s.normalizedName } ==
                            listOf("tofu fume")
                    }.suggestions
                    .map { it.normalizedName },
            )

            model.type("tof")
            model.add(
                model.uiState
                    .await { it.suggestions.isNotEmpty() }
                    .suggestions
                    .single(),
            )
            model.uiState.await { s -> s.sections.sumOf { it.items.size } == 2 }
            val added = lists.items(id).single { it.label == "Tofu fumé" }
            assertEquals(tofu.id, added.productId)
            assertEquals("world-food", added.categoryId)
        }

    @Test
    fun theOpenListFollowsItsNewIdentifierWithoutLosingTheInput() =
        runBlocking {
            val oldId = lists.createList("Courses", clock).id
            lists.addItem(oldId, "lait", "lait", null, null, "dairy", clock)
            val remaps = MutableSharedFlow<IdentifierRemap>(extraBufferCapacity = 1)
            val model = detailModel(oldId, remaps)
            model.uiState.await { it.sections.isNotEmpty() }
            model.type("pain")

            // Même contenu sous de nouveaux identifiants (reprise de compte).
            val newList = lists.createList("Courses", clock)
            lists.addItem(newList.id, "lait", "lait", null, null, "dairy", clock)
            lists.deleteList(oldId, clock)
            remaps.tryEmit(IdentifierRemap(mapOf(oldId to newList.id)))

            val state =
                model.uiState.await {
                    !it.isMissing && it.sections.isNotEmpty() &&
                        model.listId.value == newList.id
                }
            assertEquals("Courses", state.name)
            assertEquals("pain", model.input.text.toString())
            model.submit()
            model.uiState.await { s -> s.sections.sumOf { it.items.size } == 2 }
            assertEquals(listOf("lait", "pain"), lists.items(newList.id).map { it.label })
        }

    // endregion

    @Test
    fun aDoubleEnterAddsOneRow() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val model = detailModel(id)
            model.uiState.await { it.isLoaded }
            model.type("lait")
            model.submit()
            model.submit()
            model.uiState.await { s -> s.sections.sumOf { it.items.size } >= 1 }
            assertEquals(1, lists.items(id).size)
            assertEquals("", model.input.text.toString())
        }

    @Test
    fun aSuggestionTappedTwiceAddsOneRow() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val other = lists.createList("Autre", clock).id
            lists.addItem(other, "tomates", "tomate", null, null, "produce", clock)
            val model = detailModel(id)
            model.type("to")
            val suggestion =
                model.uiState
                    .await { it.suggestions.isNotEmpty() }
                    .suggestions
                    .first()
            model.add(suggestion)
            model.add(suggestion)
            model.uiState.await { s -> s.sections.sumOf { it.items.size } >= 1 }
            assertEquals(1, lists.items(id).size)
        }

    @Test
    fun aRenameOpenedBeforeARekeyFollowsTheNewIdentifier() =
        runBlocking {
            val old = lists.createList("Courses", clock)
            val moved = lists.createList("Courses", clock)
            val remaps = MutableSharedFlow<IdentifierRemap>(replay = 1)
            remaps.tryEmit(IdentifierRemap(mapOf(old.id to moved.id)))
            val model = tracked { ListsViewModel(lists, remaps) { clock } }
            model.uiState.await { it.isLoaded }
            model.rename(old.id, "Semaine")
            assertEquals(
                "Semaine",
                model.uiState
                    .await { s -> s.lists.any { it.name == "Semaine" } }
                    .lists
                    .single {
                        it.name ==
                            "Semaine"
                    }.name,
            )
            assertEquals("Semaine", lists.list(moved.id)?.name)
            assertNull(model.uiState.value.errorDetail)
        }

    // region Suites des relectures (#54)

    /** Repository dont les ajouts attendent [gate] : une écriture reste en cours le temps du test. */
    private class GatedLists(
        private val inner: ListRepository,
        val gate: CompletableDeferred<Unit> = CompletableDeferred(),
    ) : ListRepository by inner {
        override suspend fun addItem(
            listId: String,
            label: String,
            normalizedName: String,
            quantity: String?,
            productId: String?,
            categoryId: String,
            at: Instant,
        ): ListItemEntity {
            gate.await()
            return inner.addItem(listId, label, normalizedName, quantity, productId, categoryId, at)
        }
    }

    private fun gatedModel(
        listId: String,
        gated: GatedLists,
        computation: CoroutineDispatcher = Dispatchers.Unconfined,
    ) = tracked {
        ListDetailViewModel(
            listId = listId,
            lists = gated,
            products = RoomProductRepository(db),
            categories = RoomCategoryRepository(db),
            analyzer = analyzer,
            now = { clock },
            computation = computation,
        )
    }

    @Test
    fun anEntryValidatedDuringAnotherWriteIsAddedToo() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val gated = GatedLists(lists)
            val model = gatedModel(id, gated)
            model.uiState.await { it.isLoaded }

            model.type("lait")
            model.submit()
            // Le lait s'écrit encore : le pain est validé tout de même, et son texte quitte le champ.
            model.type("pain")
            model.submit()
            assertEquals("", model.input.text.toString())

            gated.gate.complete(Unit)
            model.uiState.await { s -> s.sections.sumOf { it.items.size } == 2 }
            // Dans l'ordre de validation.
            assertEquals(listOf("lait", "pain"), lists.items(id).sortedBy { it.position }.map { it.label })
        }

    @Test
    fun aDoubleTapOnASuggestionAddsItOnce() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val other = lists.createList("Autre", clock).id
            lists.addItem(other, "tomates", "tomate", null, null, "produce", clock)
            val gated = GatedLists(lists)
            val model = gatedModel(id, gated)
            model.uiState.await { it.isLoaded }
            model.type("tom")
            val tomato =
                model.uiState
                    .await { it.suggestions.isNotEmpty() }
                    .suggestions
                    .single()

            model.add(tomato)
            model.add(tomato)
            gated.gate.complete(Unit)

            model.uiState.await { s -> s.sections.sumOf { it.items.size } == 1 }
            model.type("pain")
            model.submit()
            model.uiState.await { s -> s.sections.sumOf { it.items.size } == 2 }
            assertEquals(1, lists.items(id).count { it.label == "tomates" })
        }

    @Test
    fun suggestionsAreComputedOffTheMainThread() {
        val id = runBlocking { lists.createList("Courses", clock).id }
        runBlocking {
            val other = lists.createList("Autre", clock).id
            lists.addItem(other, "tomates", "tomate", null, null, "produce", clock)
        }
        val computation = StandardTestDispatcher()
        val model = gatedModel(id, GatedLists(lists, CompletableDeferred(Unit)), computation)
        // Un écran abonné, comme en vrai : l'état n'est calculé que pour un abonné.
        val screen = CoroutineScope(Dispatchers.Unconfined).launch { model.uiState.collect {} }
        try {
            // L'index se construit sur `computation` : rien n'est chargé tant qu'il ne tourne pas.
            model.uiState.pumping(computation) { it.isLoaded }
            model.type("tom")
            Thread.sleep(SETTLE_MS)
            // Le fil principal (ici `Unconfined`) n'a pas calculé la recherche à la frappe.
            assertTrue(
                model.uiState.value.suggestions
                    .isEmpty(),
            )
            assertEquals(
                listOf("tomate"),
                model.uiState
                    .pumping(computation) { it.suggestions.isNotEmpty() }
                    .suggestions
                    .map { it.normalizedName },
            )
        } finally {
            screen.cancel()
        }
    }

    /** Fait tourner [dispatcher] jusqu'à ce que l'état réponde au prédicat (au plus 5 s). */
    private fun <T> StateFlow<T>.pumping(
        dispatcher: TestDispatcher,
        predicate: (T) -> Boolean,
    ): T {
        val deadline = System.currentTimeMillis() + PUMP_MS
        while (System.currentTimeMillis() < deadline) {
            dispatcher.scheduler.runCurrent()
            if (predicate(value)) return value
            Thread.sleep(PUMP_STEP_MS)
        }
        error("État attendu non atteint : $value")
    }

    // endregion

    private companion object {
        const val SETTLE_MS = 300L
        const val PUMP_MS = 5_000L
        const val PUMP_STEP_MS = 10L
    }
}
