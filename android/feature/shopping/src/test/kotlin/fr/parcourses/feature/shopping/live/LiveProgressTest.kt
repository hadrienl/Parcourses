package fr.parcourses.feature.shopping.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveProgressTest {
    @Test
    fun oneSegmentPerRunOfTheSameAisleAlongTheRoute() {
        val state =
            liveState(
                checked = listOf(liveItem("a", "produce", 0), liveItem("b", "produce", 0)),
                pending = listOf(liveItem("c", "bakery", 2), liveItem("d", "dairy", 4), liveItem("e", "dairy", 4)),
            )

        val model = LiveProgress.of(state)

        assertEquals(listOf(4, 2, 4), model.segments.map { it.length })
        assertEquals(listOf(0, 2, 4), model.segments.map { it.colorIndex })
        assertEquals(10, model.max)
        // Deux articles pris : la progression s'arrête à la fin du second.
        assertEquals(4, model.progress)
    }

    @Test
    fun onePointInTheMiddleOfEachItemInItsSegmentColor() {
        val state =
            liveState(checked = listOf(liveItem("a", "produce", 0)), pending = listOf(liveItem("b", "bakery", 1)))

        val model = LiveProgress.of(state)

        assertEquals(listOf(1, 3), model.points.map { it.position })
        assertEquals(listOf(0, 1), model.points.map { it.colorIndex })
    }

    @Test
    fun pointsStopAboveThirtyItems() {
        val thirty = liveState(pending = (1..30).map { liveItem("i$it") })
        val more = liveState(pending = (1..31).map { liveItem("i$it") })

        assertEquals(30, LiveProgress.of(thirty).points.size)
        assertTrue(LiveProgress.of(more).points.isEmpty())
        assertEquals(62, LiveProgress.of(more).max)
    }

    @Test
    fun neighbouringSegmentsNeverShareAColor() {
        // Rangs 0 et 6 : même couleur dans une palette de 6, décalée pour rester lisible.
        val state = liveState(pending = listOf(liveItem("a", "produce", 0), liveItem("b", "frozen", LIVE_PALETTE.size)))

        val colors = LiveProgress.of(state).segments.map { it.colorIndex }

        assertNotEquals(colors[0], colors[1])
    }

    @Test
    fun beyondFifteenAislesTheLastOnesJoinTheFifteenthSegment() {
        val state = liveState(pending = (0 until 20).map { liveItem("i$it", "aisle$it", it) })

        val model = LiveProgress.of(state)

        assertEquals(LiveProgress.MAX_SEGMENTS, model.segments.size)
        assertEquals(12, model.segments.last().length)
        assertEquals(40, model.segments.sumOf { it.length })
        assertEquals(model.max, model.segments.sumOf { it.length })
    }
}
