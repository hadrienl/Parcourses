package fr.parcourses.feature.shopping.live

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.repository.CheckSubject
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.database.entity.VisitEntity
import fr.parcourses.feature.shopping.ShoppingTest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/** Contrôleur de la Live Update, sur une vraie base Room et en temps virtuel. */
@RunWith(AndroidJUnit4::class)
class ShoppingLiveUpdatesTest : ShoppingTest() {
    private val notifier = FakeNotifier()
    private val preferences = FakePreferences()
    private val log = RecordingLog()

    private fun TestScope.controller(
        scope: CoroutineScope = backgroundScope,
        remaps: Flow<IdentifierRemap> = emptyFlow(),
        minInterval: Duration = Duration.ZERO,
    ) = ShoppingLiveUpdates(
        notifier = notifier,
        visits = visits,
        lists = lists,
        analyzer = analyzer,
        preferences = preferences,
        scope = scope,
        remaps = remaps,
        now = clock,
        minInterval = minInterval,
        log = log,
    )

    /** Une liste de trois articles et sa visite ouverte, avec l'état que l'écran publierait. */
    private suspend fun shopping(): Pair<VisitEntity, ShoppingLiveState> {
        val (listId, items) =
            newList(Triple("lait", "dairy", null), Triple("pain", "bakery", null), Triple("pommes", "produce", null))
        val visit = visits.startVisit(storeId, listId, false, clock())
        val state =
            ShoppingLiveState(
                visitId = visit.id,
                listId = listId,
                listName = "Courses",
                storeName = "Carrefour",
                pending = items.reversed().map { LiveItem(it.id, it.label, it.categoryId) },
                checked = emptyList(),
            )
        return visit to state
    }

    private val ShoppingLiveState.nextLabel get() = next?.label

    // region Démarrage, mise à jour, fin

    @Test
    fun aVisitIsShownUpdatedOnlyOnChangeThenEnded() =
        runTest(main) {
            val (visit, state) = shopping()
            val live = controller()

            live.publish(state)
            runCurrent()
            assertEquals("pommes", notifier.state?.nextLabel)
            assertEquals(45.minutes, notifier.posts.single().second)

            live.publish(state)
            runCurrent()
            assertEquals(1, notifier.posts.size)

            live.publish(state.copy(pending = state.pending.drop(1)))
            runCurrent()
            assertEquals(2, notifier.posts.size)
            assertEquals("pain", notifier.state?.nextLabel)

            live.end(visit.id)
            runCurrent()
            assertEquals(LiveUpdateNotifier.Active.None, notifier.shown)
        }

    @Test
    fun theEndOfAnotherVisitLeavesTheNotificationAlone() =
        runTest(main) {
            val (_, state) = shopping()
            val live = controller()
            live.publish(state)
            runCurrent()

            live.end("une-autre-visite")
            runCurrent()

            assertEquals(state, notifier.state)
        }

    @Test
    fun theStateOfAClosedVisitNeverReplacesTheOpenOne() =
        runTest(main) {
            val (old, oldState) = shopping()
            val live = controller()
            // Une visite neuve ferme l'ancienne (une seule visite ouverte), puis un écran attardé republie l'ancienne.
            val (_, newState) = shopping()
            assertTrue(visits.visit(old.id)?.endedAt != null || visits.visit(old.id) == null)
            live.publish(newState)
            runCurrent()

            live.publish(oldState)
            runCurrent()

            assertEquals(newState.visitId, notifier.state?.visitId)
        }

    @Test
    fun aClosedVisitTakesItsNotificationAway() =
        runTest(main) {
            val (visit, state) = shopping()
            val live = controller()
            live.publish(state)
            runCurrent()

            visits.closeVisit(visit.id, clock())
            live.publish(state.copy(pending = state.pending.drop(1)))
            runCurrent()

            assertEquals(LiveUpdateNotifier.Active.None, notifier.shown)
            assertTrue(log.entries.any { "visite close" in it })
        }

    @Test
    fun aListWithNothingToShowIsNotPosted() =
        runTest(main) {
            val (_, state) = shopping()
            val live = controller()

            live.publish(state.copy(pending = emptyList()))
            runCurrent()

            assertTrue(notifier.posts.isEmpty())
        }

    @Test
    fun updatesAreSpacedSoTheSystemDoesNotDropThem() =
        runTest(main) {
            val (_, state) = shopping()
            val live = controller(minInterval = 300.milliseconds)
            live.publish(state)
            runCurrent()

            live.publish(state.copy(pending = state.pending.drop(1)))
            live.publish(state.copy(pending = state.pending.drop(2)))
            runCurrent()
            assertEquals(1, notifier.posts.size)

            after(300)
            // Seul le dernier état part.
            assertEquals(2, notifier.posts.size)
            assertEquals("lait", notifier.state?.nextLabel)
        }

    // endregion

    // region Orphelines, expiration, autorisation

    @Test
    fun atLaunchANotificationWithoutAnOpenVisitIsRemoved() =
        runTest(main) {
            val (visit, state) = shopping()
            visits.closeVisit(visit.id, clock())
            notifier.shown = LiveUpdateNotifier.Active.Shown(state)

            controller().reconcile()
            runCurrent()

            assertEquals(LiveUpdateNotifier.Active.None, notifier.shown)
        }

    @Test
    fun atLaunchTheNotificationOfAnUnknownVisitIsRemoved() =
        runTest(main) {
            notifier.shown = LiveUpdateNotifier.Active.Shown(liveState(pending = listOf(liveItem("a"))))

            val done = controller().reconcile()
            runCurrent()

            assertTrue(done.isCompleted)
            assertEquals(LiveUpdateNotifier.Active.None, notifier.shown)
        }

    @Test
    fun atLaunchAnUnreadableNotificationIsRemoved() =
        runTest(main) {
            notifier.shown = LiveUpdateNotifier.Active.Unreadable

            controller().reconcile()
            runCurrent()

            assertEquals(LiveUpdateNotifier.Active.None, notifier.shown)
            assertTrue(log.entries.any { "illisible" in it })
        }

    @Test
    fun atLaunchTheNotificationOfTheOpenVisitStays() =
        runTest(main) {
            val (_, state) = shopping()
            notifier.shown = LiveUpdateNotifier.Active.Shown(state)

            controller().reconcile()
            runCurrent()

            assertEquals(state, notifier.state)
        }

    @Test
    fun theTimeoutCountsFromTheLastCheck() =
        runTest(main) {
            val (visit, state) = shopping()
            val live = controller()
            offset = 10.minutes
            visits.checkItem(visit.id, state.pending.first().id, CheckSubject.Category("produce"), clock())
            offset = 25.minutes

            live.publish(state.copy(pending = state.pending.drop(1), checked = state.pending.take(1)))
            runCurrent()

            // Coche à 10 min, affichage à 25 min : il reste 30 min avant la péremption.
            assertEquals(30.minutes, notifier.posts.single().second)
        }

    @Test
    fun aVisitWithoutACheckFor45MinutesIsNoLongerShown() =
        runTest(main) {
            val (_, state) = shopping()
            notifier.shown = LiveUpdateNotifier.Active.Shown(state)
            offset = 45.minutes

            controller().reconcile()
            runCurrent()

            assertEquals(LiveUpdateNotifier.Active.None, notifier.shown)
            assertTrue(log.entries.any { "périmée" in it })
        }

    @Test
    fun withoutPermissionNothingIsShownUntilItIsGranted() =
        runTest(main) {
            val (_, state) = shopping()
            notifier.allowed = false
            val live = controller()

            live.publish(state)
            live.publish(state.copy(pending = state.pending.drop(1)))
            runCurrent()
            assertTrue(notifier.posts.isEmpty())
            // Une seule trace, pas une par mise à jour.
            assertEquals(1, log.entries.count { "non autorisées" in it })

            notifier.allowed = true
            live.refresh()
            runCurrent()
            assertEquals("pain", notifier.state?.nextLabel)
        }

    @Test
    fun aDismissedNotificationDoesNotComeBackForThatVisit() =
        runTest(main) {
            val (_, state) = shopping()
            val live = controller()
            live.publish(state)
            runCurrent()
            notifier.shown = LiveUpdateNotifier.Active.None

            live.dismissed(state.visitId)
            live.publish(state.copy(pending = state.pending.drop(1)))
            runCurrent()

            assertEquals(1, notifier.posts.size)
            assertEquals(state.visitId, preferences.dismissedVisitId)
        }

    @Test
    fun aRekeyRepostsWithTheNewIdentifiers() =
        runTest(main) {
            val (visit, state) = shopping()
            val remaps = MutableSharedFlow<IdentifierRemap>()
            val live = controller(remaps = remaps)
            live.publish(state)
            runCurrent()

            // La base a changé d'identifiants (reprise de compte) : ici, la visite et le premier article.
            val newVisit = "00000000-0000-4000-8000-00000000abcd"
            db.visits().upsert(visit.copy(id = newVisit))
            remaps.emit(IdentifierRemap(mapOf(visit.id to newVisit)))
            runCurrent()

            assertEquals(newVisit, notifier.state?.visitId)
            assertEquals(2, notifier.posts.size)
        }

    @Test
    fun aRekeyAfterTheProcessDiedFollowsTheShownNotification() =
        runTest(main) {
            val (visit, state) = shopping()
            notifier.shown = LiveUpdateNotifier.Active.Shown(state)
            val remaps = MutableSharedFlow<IdentifierRemap>()
            controller(remaps = remaps)
            runCurrent()

            val newVisit = "00000000-0000-4000-8000-00000000abce"
            db.visits().upsert(visit.copy(id = newVisit))
            remaps.emit(IdentifierRemap(mapOf(visit.id to newVisit)))
            runCurrent()

            assertEquals(newVisit, notifier.state?.visitId)
        }

    @Test
    fun aDeletedListTakesItsNotificationAway() =
        runTest(main) {
            val (_, state) = shopping()
            val live = controller()
            live.publish(state)
            runCurrent()

            lists.deleteList(state.listId, clock())
            live.reconcile()
            runCurrent()

            assertEquals(LiveUpdateNotifier.Active.None, notifier.shown)
        }

    // endregion

    // region « Cocher le suivant »

    @Test
    fun anItemNoLongerToTakeIsNeverChecked() =
        runTest(main) {
            val (visit, state) = shopping()
            val live = controller()
            live.publish(state)
            runCurrent()
            // Passé introuvable à l'écran entre l'affichage et l'appui.
            lists.setNotFound(state.next!!.id, clock())

            live.checkNext(visit.id, state.next!!.id)
            live.checkNext(visit.id, "un-article-d-un-ancien-etat")
            runCurrent()

            assertTrue(visits.checks(visit.id).isEmpty())
            assertEquals("pain", notifier.state?.next?.label)
        }

    @Test
    fun checkNextChecksTheDisplayedItemAndShowsTheFollowingOne() =
        runTest(main) {
            val (visit, state) = shopping()
            val live = controller()
            live.publish(state)
            runCurrent()
            val next = state.next!!

            val done = live.checkNext(visit.id, next.id)
            runCurrent()

            assertTrue(done.isCompleted)
            assertEquals(1, visits.checks(visit.id).size)
            assertEquals(next.id, visits.checks(visit.id).single().itemId)
            assertTrue(lists.items(state.listId).first { it.id == next.id }.checkedAt != null)
            assertEquals("pain", notifier.state?.nextLabel)
            assertEquals(listOf(next.id), notifier.state?.checked?.map { it.id })
            // Même retenue que l'écran : la coche ne part pas avant la fin du délai d'annulation.
            val insertion = db.outbox().pending().first { it.entityId == visits.checks(visit.id).single().id }
            assertEquals(clock() + 5.seconds, insertion.nextAttemptAt)
        }

    @Test
    fun aDoubleTapOnCheckNextChecksOnce() =
        runTest(main) {
            val (visit, state) = shopping()
            val live = controller()
            live.publish(state)
            runCurrent()

            // Deux appuis sur la même notification : les deux portent le même article.
            live.checkNext(visit.id, state.next!!.id)
            live.checkNext(visit.id, state.next!!.id)
            runCurrent()

            assertEquals(1, visits.checks(visit.id).size)
            assertEquals("pain", notifier.state?.nextLabel)
            assertTrue(log.entries.any { "déjà coché" in it })
            assertFalse(log.entries.any { it.startsWith("E ") })
        }

    @Test
    fun checkNextWorksAfterTheProcessDied() =
        runTest(main) {
            val (visit, state) = shopping()
            // Processus neuf : le contrôleur ne sait rien, la notification est encore affichée.
            notifier.shown = LiveUpdateNotifier.Active.Shown(state)
            val live = controller()

            live.checkNext(visit.id, state.next!!.id)
            runCurrent()

            assertEquals(1, visits.checks(visit.id).size)
            assertEquals("pain", notifier.state?.nextLabel)
        }

    @Test
    fun checkNextFromAnotherVisitsNotificationIsIgnored() =
        runTest(main) {
            val (visit, state) = shopping()
            val live = controller()
            live.publish(state)
            runCurrent()

            live.checkNext("une-autre-visite", state.next!!.id)
            runCurrent()

            assertTrue(visits.checks(visit.id).isEmpty())
            assertTrue(log.entries.any { "ne suit plus" in it })
        }

    @Test
    fun checkNextOnAClosedVisitRemovesTheNotification() =
        runTest(main) {
            val (visit, state) = shopping()
            val live = controller()
            live.publish(state)
            runCurrent()
            visits.closeVisit(visit.id, clock())

            live.checkNext(visit.id, state.next!!.id)
            runCurrent()

            assertEquals(LiveUpdateNotifier.Active.None, notifier.shown)
            assertTrue(log.entries.any { it.startsWith("W « Cocher le suivant » refusé") })
        }

    @Test
    fun anItemCheckedOnScreenIsNeverShownAsNext() =
        runTest(main) {
            val (visit, state) = shopping()
            val live = controller()
            // L'écran a coché le premier article mais son état n'a pas encore suivi (tri en attente).
            visits.checkItem(visit.id, state.next!!.id, CheckSubject.Category("produce"), clock())

            live.publish(state)
            runCurrent()

            assertEquals("pain", notifier.state?.nextLabel)
        }

    // endregion
}
