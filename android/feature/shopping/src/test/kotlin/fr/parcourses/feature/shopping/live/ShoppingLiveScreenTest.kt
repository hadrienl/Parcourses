package fr.parcourses.feature.shopping.live

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.feature.shopping.ShoppingTest
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

/** Le mode courses et la Live Update ensemble : même « suivant », dans les deux sens. */
@RunWith(AndroidJUnit4::class)
class ShoppingLiveScreenTest : ShoppingTest() {
    private val notifier = FakeNotifier()
    private val log = RecordingLog()

    private suspend fun groceries() =
        newList(Triple("lait", "dairy", null), Triple("pain", "bakery", null), Triple("pommes", "produce", null))

    private fun TestScope.connected(): ShoppingLiveUpdates =
        ShoppingLiveUpdates(
            notifier = notifier,
            visits = visits,
            lists = lists,
            analyzer = analyzer,
            preferences = FakePreferences(),
            scope = backgroundScope,
            now = clock,
            minInterval = Duration.ZERO,
            log = log,
        ).also { liveSink = it }

    @Test
    fun theScreenPublishesItsDisplayedNextItem() =
        runTest(main) {
            val sink = RecordingSink().also { liveSink = it }
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)

            // Ordre générique : par rayon, fruits et légumes d'abord.
            val live = sink.published.last()
            assertEquals(
                state.sections
                    .flatMap { it.rows }
                    .first()
                    .id,
                live.next?.id,
            )
            assertEquals("pommes", live.next?.label)
            assertEquals("Fruits et légumes", live.next?.aisleLabel)
            assertEquals(visits.openVisit()!!.id, live.visitId)
            assertEquals("Carrefour", live.storeName)
            assertEquals(3, live.total)

            // Juste cochée, la ligne reste à sa place : la Live Update passe déjà au suivant.
            model.toggle(state.row("pommes"))
            runCurrent()
            assertEquals(
                "pain",
                sink.published
                    .last()
                    .next
                    ?.label,
            )
            assertEquals(2, sink.published.last().remaining)
        }

    @Test
    fun withoutAStoreThereIsNoLiveUpdate() =
        runTest(main) {
            val sink = RecordingSink().also { liveSink = it }
            val (listId, _) = groceries()
            started(model(listId, store = null))

            assertTrue(sink.published.isEmpty())
        }

    @Test
    fun finishingEndsTheLiveUpdate() =
        runTest(main) {
            val sink = RecordingSink().also { liveSink = it }
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            val visitId = visits.openVisit()!!.id
            model.toggle(state.row("pommes"))
            runCurrent()

            model.finish(keepRemaining = true)
            runCurrent()

            assertEquals(listOf(visitId), sink.ended)
        }

    @Test
    fun expiryEndsTheLiveUpdate() =
        runTest(main) {
            val sink = RecordingSink().also { liveSink = it }
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pommes"))
            after(5_000)
            val visitId = visits.openVisit()!!.id
            val published = sink.published.size

            offset = 46.minutes
            model.foregrounded()
            runCurrent()

            assertEquals(listOf(visitId), sink.ended)
            // Plus rien n'est publié pour une visite expirée.
            assertEquals(published, sink.published.size)
        }

    @Test
    fun checkNextFromTheNotificationReachesTheOpenScreen() =
        runTest(main) {
            val live = connected()
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)
            assertEquals("pommes", notifier.state?.next?.label)
            val visitId = visits.openVisit()!!.id

            live.checkNext(visitId, notifier.state!!.next!!.id)
            runCurrent()
            after(600)

            val screen = model.uiState.value
            assertEquals(listOf("pommes"), screen.basket.map { it.label })
            assertEquals("pain", screen.toBuy.first { !it.isChecked }.label)
            assertEquals("pain", notifier.state?.next?.label)
            assertNull(screen.errorMessage)
        }

    @Test
    fun theScreenAndTheNotificationCheckingTogetherCountOnce() =
        runTest(main) {
            val live = connected()
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            val visitId = visits.openVisit()!!.id

            // Même article, au même moment, depuis l'écran et depuis la notification.
            model.toggle(state.row("pommes"))
            live.checkNext(visitId, state.row("pommes").id)
            runCurrent()
            after(600)

            assertEquals(1, visits.checks(visitId).size)
            assertNull(model.uiState.value.errorMessage)
            assertEquals("pain", notifier.state?.next?.label)
            assertTrue(log.entries.none { it.startsWith("E ") })
        }

    @Test
    fun tappingOnScreenAnItemAlreadyCheckedFromTheNotificationIsSilent() =
        runTest(main) {
            val live = connected()
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            val visitId = visits.openVisit()!!.id
            live.checkNext(visitId, state.row("pommes").id)
            runCurrent()

            // L'écran montrait encore la ligne à prendre : l'appui ne coche pas deux fois et n'affiche aucune erreur.
            model.toggle(state.row("pommes"))
            runCurrent()

            assertEquals(1, visits.checks(visitId).size)
            assertNull(model.uiState.value.errorMessage)
            assertEquals(
                listOf("pommes"),
                model.uiState.value.basket
                    .map { it.label },
            )
        }

    @Test
    fun leavingTheScreenKeepsTheNotificationOfTheStillOpenVisit() =
        runTest(main) {
            val live = connected()
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)
            val visitId = visits.openVisit()!!.id

            // Retour : l'écran disparaît, la visite reste ouverte (elle expirera après 45 min sans coche).
            viewModels.clear()
            runCurrent()
            live.checkNext(visitId, notifier.state!!.next!!.id)
            runCurrent()

            assertEquals(1, visits.checks(visitId).size)
            assertEquals("pain", notifier.state?.next?.label)
        }
}
