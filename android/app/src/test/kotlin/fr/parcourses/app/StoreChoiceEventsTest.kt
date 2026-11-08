package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import fr.parcourses.feature.storepicker.StorePickerOutcome
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Le choix du magasin rejoue ce que fait la navigation : le sélecteur est dépilé et le choix émis dans la même
 * exécution, puis le collecteur toujours composé (`ParcoursesNavHost`) le lit plus tard et ouvre le mode courses.
 */
class StoreChoiceEventsTest {
    private val store = StorePickerOutcome.Store("s1")

    /** Collecteur de `ParcoursesNavHost` : il ouvre le mode courses, filtré sur la liste du choix. */
    private fun kotlinx.coroutines.CoroutineScope.navHost(
        events: StoreChoiceEvents,
        stack: MutableList<NavKey>,
    ) = launch { events.choices.collect { stack.openShopping(it) } }

    @Test
    fun aChoiceMadeBeforeTheCollectorRunsStillOpensShopping() =
        runTest {
            val events = StoreChoiceEvents()
            val picker = Route.StorePicker("a")
            val stack = mutableListOf<NavKey>(Route.Lists, Route.ListDetail("a"), picker)

            // Choix, dépilage et émission d'un seul tenant : aucun collecteur n'a encore tourné.
            stack.finishStorePicker(picker.slot, store)?.let(events::offer)
            val host = navHost(events, stack)
            testScheduler.runCurrent()
            host.cancel()

            val shopping = stack.last() as Route.Shopping
            assertEquals("a", shopping.listId)
            assertEquals("s1", shopping.storeId)
        }

    @Test
    fun theSharedFlowItReplacesLostThatChoice() =
        runTest {
            // Le piège d'origine : sans rejeu, l'émission faite avant l'abonnement est perdue.
            val old = MutableSharedFlow<StoreChoice>(extraBufferCapacity = 1)
            val stack = mutableListOf<NavKey>(Route.Lists, Route.ListDetail("a"))
            old.tryEmit(StoreChoice("a", store))
            val host = launch { old.collect { stack.openShopping(it) } }
            testScheduler.runCurrent()
            host.cancel()
            assertEquals(2, stack.size)
        }

    @Test
    fun aChoiceForAnotherListDoesNotOpenAVisitAndIsConsumed() =
        runTest {
            val events = StoreChoiceEvents()
            val stack = mutableListOf<NavKey>(Route.Lists, Route.ListDetail("b"))
            events.offer(StoreChoice("a", store))
            val host = navHost(events, stack)
            testScheduler.runCurrent()
            assertEquals(2, stack.size)

            // Consommé : il ne ressurgit pas quand la bonne liste est ouverte ensuite.
            stack += Route.ListDetail("a")
            testScheduler.runCurrent()
            host.cancel()
            assertTrue(stack.none { it is Route.Shopping })
        }

    @Test
    fun aRecomposedCollectorDoesNotReplayAChoice() =
        runTest {
            val events = StoreChoiceEvents()
            val stack = mutableListOf<NavKey>(Route.Lists, Route.ListDetail("a"))
            events.offer(StoreChoice("a", store))
            val first = navHost(events, stack)
            testScheduler.runCurrent()
            first.cancel()
            // Recréation de l'activité : un nouveau collecteur, revenu sur la liste, ne rouvre rien.
            stack.removeAt(stack.lastIndex)
            val second = navHost(events, stack)
            testScheduler.runCurrent()
            second.cancel()
            assertEquals(2, stack.size)
        }
}
