package fr.parcourses.core.designsystem

import fr.parcourses.core.designsystem.MarkerPlace.Above
import fr.parcourses.core.designsystem.MarkerPlace.Absent
import fr.parcourses.core.designsystem.MarkerPlace.Below
import fr.parcourses.core.designsystem.MarkerPlace.Visible
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Tronçons du trait unique (#115) : mêmes cas que `threadTrackSegments` sur iOS. */
class ThreadTrackSegmentsTest {
    private val height = 800f

    @Test
    fun theTrackRunsFromFirstToLastMarkerAndIsWalkedUpToTheNextBead() {
        assertEquals(
            ThreadTrackSegments(top = 40f, junction = 200f, bottom = 600f),
            threadTrackSegments(Visible(40f), Visible(200f), Visible(600f), height),
        )
    }

    @Test
    fun nothingIsWalkedWhileTheListIsPrepared() {
        // Écran Liste : la perle suivante est le premier marqueur.
        assertEquals(
            ThreadTrackSegments(top = 40f, junction = 40f, bottom = 600f),
            threadTrackSegments(Visible(40f), Visible(40f), Visible(600f), height),
        )
    }

    @Test
    fun everythingIsWalkedWhenNoBeadIsLeft() {
        assertEquals(
            ThreadTrackSegments(top = 40f, junction = 600f, bottom = 600f),
            threadTrackSegments(Visible(40f), Absent, Visible(600f), height),
        )
    }

    @Test
    fun anEndOffScreenStopsAtTheEdge() {
        assertEquals(
            ThreadTrackSegments(top = 0f, junction = 300f, bottom = height),
            threadTrackSegments(Above, Visible(300f), Below, height),
        )
    }

    @Test
    fun aNextBeadOffScreenDecidesTheWholeVisibleTrack() {
        // Au-dessus : tout le visible est à parcourir ; au-dessous : tout est parcouru.
        assertEquals(
            ThreadTrackSegments(top = 0f, junction = 0f, bottom = 600f),
            threadTrackSegments(Above, Above, Visible(600f), height),
        )
        assertEquals(
            ThreadTrackSegments(top = 40f, junction = height, bottom = height),
            threadTrackSegments(Visible(40f), Below, Below, height),
        )
    }

    @Test
    fun aMarkerPartlyOffScreenIsClampedToTheList() {
        assertEquals(
            ThreadTrackSegments(top = 0f, junction = 0f, bottom = height),
            threadTrackSegments(Visible(-12f), Visible(-12f), Visible(height + 20f), height),
        )
    }

    @Test
    fun noTrackIsDrawnWhenNothingOfItIsVisible() {
        assertNull(threadTrackSegments(Absent, Absent, Absent, height))
        // Un seul arrêt : pas de trait.
        assertNull(threadTrackSegments(Visible(40f), Visible(40f), Visible(40f), height))
        // Fil entièrement au-dessous ou au-dessus de l'écran.
        assertNull(threadTrackSegments(Below, Below, Below, height))
        assertNull(threadTrackSegments(Above, Absent, Above, height))
    }
}
