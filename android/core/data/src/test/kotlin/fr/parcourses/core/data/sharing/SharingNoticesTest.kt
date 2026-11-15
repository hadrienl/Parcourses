package fr.parcourses.core.data.sharing

import org.junit.Assert.assertEquals
import org.junit.Test

/** Messages d'accès (#87, lot 87.6) : une liste retirée qui revient perd son message « n'est plus partagée ». */
class SharingNoticesTest {
    private val notices = SharingNotices()
    private val removed = AccessChange.Removed("a", "Courses")

    @Test
    fun aRemovedListThatComesBackLosesItsNotice() {
        notices.listsPresent(setOf("a", "b"))
        notices.post(removed)
        // Émission en retard qui montre encore la liste : rien n'est effacé.
        notices.listsPresent(setOf("a", "b"))
        notices.listsPresent(setOf("b"))
        assertEquals(listOf(removed), notices.notices.value)

        // Réinvitée et acceptée : la liste revient.
        notices.listsPresent(setOf("a", "b"))
        assertEquals(emptyList<AccessChange>(), notices.notices.value)
    }

    @Test
    fun theFirstListOfTheLaunchClearsNothing() {
        notices.post(removed)
        notices.listsPresent(setOf("a"))
        assertEquals(listOf(removed), notices.notices.value)
    }
}
