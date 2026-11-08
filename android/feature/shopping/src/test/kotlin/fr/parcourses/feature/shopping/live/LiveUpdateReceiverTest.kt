package fr.parcourses.feature.shopping.live

import android.app.Application
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.feature.shopping.ShoppingTest
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import kotlin.time.Duration

/** Application de test qui porte le contrôleur, comme `ParcoursesApp`. */
class LiveHostApp :
    Application(),
    LiveUpdateHost {
    override lateinit var liveUpdates: ShoppingLiveUpdates
}

@RunWith(AndroidJUnit4::class)
@Config(application = LiveHostApp::class)
class LiveUpdateReceiverTest : ShoppingTest() {
    private val notifier = FakeNotifier()
    private val preferences = FakePreferences()
    private val app get() = ApplicationProvider.getApplicationContext<LiveHostApp>()

    private fun intent(
        action: String,
        visitId: String?,
        itemId: String? = null,
    ) = Intent(action)
        .putExtra(LiveUpdateReceiver.EXTRA_VISIT_ID, visitId)
        .putExtra(LiveUpdateReceiver.EXTRA_ITEM_ID, itemId)

    @Test
    fun checkNextWritesTheCheckWithoutTheApp() =
        runTest(main) {
            app.liveUpdates =
                ShoppingLiveUpdates(
                    notifier,
                    visits,
                    lists,
                    analyzer,
                    preferences,
                    backgroundScope,
                    now = clock,
                    minInterval = Duration.ZERO,
                )
            val (listId, items) = newList(Triple("lait", "dairy", null), Triple("pain", "bakery", null))
            val visit = visits.startVisit(storeId, listId, false, clock())
            val state =
                ShoppingLiveState(
                    visit.id,
                    listId,
                    "Courses",
                    "Carrefour",
                    items.map {
                        LiveItem(it.id, it.label, it.categoryId)
                    },
                    emptyList(),
                )
            notifier.shown = LiveUpdateNotifier.Active.Shown(state)
            val receiver = LiveUpdateReceiver()

            // Deux appuis rapprochés sur l'action : une seule coche.
            receiver.onReceive(app, intent(LiveUpdateReceiver.ACTION_CHECK_NEXT, visit.id, items[0].id))
            receiver.onReceive(app, intent(LiveUpdateReceiver.ACTION_CHECK_NEXT, visit.id, items[0].id))
            runCurrent()

            assertEquals(listOf(items[0].id), visits.checks(visit.id).map { it.itemId })
            assertEquals("pain", notifier.state?.next?.label)
        }

    @Test
    fun aDismissalIsRemembered() =
        runTest(main) {
            app.liveUpdates =
                ShoppingLiveUpdates(
                    notifier,
                    visits,
                    lists,
                    analyzer,
                    preferences,
                    backgroundScope,
                    now = clock,
                    minInterval = Duration.ZERO,
                )

            LiveUpdateReceiver().onReceive(app, intent(LiveUpdateReceiver.ACTION_DISMISSED, "v1"))
            runCurrent()

            assertEquals("v1", preferences.dismissedVisitId)
        }

    @Test
    fun anIncompleteActionIsIgnored() =
        runTest(main) {
            app.liveUpdates =
                ShoppingLiveUpdates(
                    notifier,
                    visits,
                    lists,
                    analyzer,
                    preferences,
                    backgroundScope,
                    now = clock,
                    minInterval = Duration.ZERO,
                )

            LiveUpdateReceiver().onReceive(app, intent(LiveUpdateReceiver.ACTION_CHECK_NEXT, null, "a"))
            LiveUpdateReceiver().onReceive(app, intent(LiveUpdateReceiver.ACTION_CHECK_NEXT, "v1", null))
            runCurrent()

            assertTrue(db.checks().getByVisit("v1").isEmpty())
        }
}
