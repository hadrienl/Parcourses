package fr.parcourses.core.network

import fr.parcourses.core.network.dto.CategoryRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

class CategoryMapTest {
    private val map = CategoryMap(listOf(CategoryRow(4, "dairy", "Crèmerie", 70)))
    private val date = Instant.fromEpochSeconds(1_800_000_000)

    @Test
    fun translatesBothWays() {
        assertEquals(4.toShort(), map.remoteId("dairy"))
        assertEquals("dairy", map.slug(4))
        assertNull(map.remoteId("other"))
    }

    @Test
    fun aMissingSlugIsReloadedAtMostOncePerLifetime() {
        assertFalse(map.shouldReload("dairy", date))
        assertTrue(map.shouldReload("x", date))
        map.markMissing("x", date)
        assertFalse(map.shouldReload("x", date + 10.seconds))
        assertTrue(map.shouldReload("x", date + CategoryMap.MISSING_SLUG_LIFETIME))
    }
}
