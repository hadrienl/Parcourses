package fr.parcourses.core.data.sharing

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Instant

/** Écho des signaux `items` (#87 §6.2) : 2 s après un envoi vers la même liste, pas au-delà, pas ailleurs. */
class RecentSendsTest {
    private var now = Instant.fromEpochSeconds(1_000)
    private val sends = RecentSends(now = { now })

    @Test
    fun aSignalWithinTwoSecondsOfASendToTheSameListIsAnEcho() {
        assertFalse(sends.isEcho("a"))
        sends.record("a")
        now += 1_999.milliseconds
        assertTrue(sends.isEcho("a"))
        assertFalse(sends.isEcho("b"))
        now += 1.milliseconds
        assertFalse(sends.isEcho("a"))
    }
}
