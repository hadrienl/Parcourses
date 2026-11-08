package fr.parcourses.app

import fr.parcourses.feature.storepicker.StorePickerOutcome
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class StoreChoiceEventsTest {
    private val choice = StoreChoice("a", StorePickerOutcome.Store("s1"))

    @Test
    fun aChoiceOfferedBeforeAnyCollectorIsKeptForIt() =
        runTest {
            // Le piège du `SharedFlow` sans rejeu : le choix est émis alors que personne ne collecte encore.
            val events = StoreChoiceEvents()
            events.offer(choice)
            assertEquals(choice, events.choices.first())
        }

    @Test
    fun eachChoiceIsDeliveredOnceAndInOrder() =
        runTest {
            val events = StoreChoiceEvents()
            val other = StoreChoice("b", StorePickerOutcome.WithoutStore)
            events.offer(choice)
            events.offer(other)
            val received = mutableListOf<StoreChoice>()
            val job = launch { events.choices.collect { received += it } }
            testScheduler.runCurrent()
            job.cancel()
            assertEquals(listOf(choice, other), received)
            // Un second collecteur ne revoit rien : consommation unique.
            val again = mutableListOf<StoreChoice>()
            val second = launch { events.choices.collect { again += it } }
            testScheduler.runCurrent()
            second.cancel()
            assertEquals(emptyList<StoreChoice>(), again)
        }
}
