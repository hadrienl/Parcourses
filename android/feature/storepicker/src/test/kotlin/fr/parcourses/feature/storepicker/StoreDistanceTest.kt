package fr.parcourses.feature.storepicker

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Locale

class StoreDistanceTest {
    private fun text(metres: Double) = StoreDistance.text(metres, Locale.FRANCE)

    @Test
    fun metresAreRoundedToTenAndKilometresToOneDecimal() {
        assertEquals("40 m", text(42.0))
        assertEquals("850 m", text(847.0))
        assertEquals("1,2 km", text(1_234.0))
        assertEquals("10,0 km", text(9_999.0))
    }

    @Test
    fun almostAKilometreIsNeverWrittenAsAThousandMetres() {
        assertEquals("1,0 km", text(996.0))
        assertEquals("990 m", text(994.0))
    }
}
