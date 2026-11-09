package fr.parcourses.core.designsystem

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class TokensTest {
    private val themes = mapOf("clair" to LightTicketColors, "sombre" to DarkTicketColors)

    /** Rapport de contraste WCAG 2.2. */
    private fun contrast(
        a: Color,
        b: Color,
    ): Double {
        val (light, dark) = listOf(a.luminance(), b.luminance()).sortedDescending()
        return (light + 0.05) / (dark + 0.05)
    }

    private fun assertContrast(
        theme: String,
        name: String,
        fg: Color,
        bg: Color,
        minimum: Double,
    ) {
        val ratio = contrast(fg, bg)
        assertTrue("$theme, $name : ${"%.2f".format(ratio)}:1 < $minimum:1", ratio >= minimum)
    }

    @Test
    fun textReachesAaOnPaperAndOnTheBars() {
        themes.forEach { (theme, c) ->
            // Texte (4,5:1) : encre, encre atténuée, accent, rouge destructif sur le papier et sur sa bordure.
            listOf(c.paper, c.paperEdge).forEach { bg ->
                assertContrast(theme, "encre", c.ink, bg, AA_TEXT)
                assertContrast(theme, "encre atténuée", c.inkMuted, bg, AA_TEXT)
                assertContrast(theme, "accent", c.accent, bg, AA_TEXT)
            }
            assertContrast(theme, "action destructive", c.destructive, c.paper, AA_TEXT)
            assertContrast(theme, "case cochée", c.checked, c.paper, AA_TEXT)
            // Boutons pleins, barre « Annuler » (encre inversée) et son action.
            assertContrast(theme, "texte des boutons pleins", c.onAccent, c.accent, AA_TEXT)
            assertContrast(theme, "texte de la barre Annuler", c.paper, c.ink, AA_TEXT)
            assertContrast(theme, "action Annuler", c.inverseAccent, c.ink, AA_TEXT)
            assertContrast(theme, "titre sur le bureau", c.ink, c.desk, AA_TEXT)
        }
    }

    @Test
    fun graphicsReachThreeToOne() {
        themes.forEach { (theme, c) ->
            // Composants graphiques (1.4.11) : icônes de rayon, fil parcouru, fil inactif en contraste élevé.
            listOf(c.aisle.fresh, c.aisle.dairy, c.aisle.grocery, c.aisle.hygiene, c.aisle.bio).forEach {
                assertContrast(theme, "rayon $it", it, c.paper, AA_GRAPHICS)
            }
            assertContrast(theme, "fil parcouru", c.thread, c.paper, AA_GRAPHICS)
            assertContrast(theme, "fil inactif (contraste élevé)", c.threadIdleHighContrast, c.paper, AA_GRAPHICS)
            assertContrast(theme, "bord des cartes de magasin", c.threadIdleHighContrast, c.paper, AA_GRAPHICS)
        }
    }

    @Test
    fun everySharedCategoryHasAnIconAndAFamily() {
        // Le dictionnaire partagé fait foi : un rayon ajouté sans icône ni couleur ferait échouer ce test.
        val json = File("../../../shared/categories/categories.json").readText()
        val ids = Regex("\"id\":\\s*\"([a-z-]+)\"").findAll(json).map { it.groupValues[1] }.toList()
        assertTrue(ids.size >= 20)
        ids.forEach { id ->
            if (id == "other") {
                assertEquals(AisleFamily.Other, AisleFamily.of(id))
                assertEquals(R.drawable.ic_cat_other, categoryIcon(id))
            } else {
                assertNotEquals("famille de $id", AisleFamily.Other, AisleFamily.of(id))
                assertNotEquals("icône de $id", R.drawable.ic_cat_other, categoryIcon(id))
            }
        }
        assertEquals(LightTicketColors.inkMuted, LightTicketColors.aisleColor("inconnu"))
    }

    @Test
    fun theThreadIsWalkedUpToTheNextBead() {
        val p = ThreadSegment.Passed
        val a = ThreadSegment.Ahead
        val n = ThreadSegment.None
        // Rayon, article coché, article suivant, article à venir.
        assertEquals(listOf(n to p, p to p, p to a, a to n), threadSegments(count = 4, next = 2))
        // Tout est pris : le fil est parcouru jusqu'au bout.
        assertEquals(listOf(n to p, p to n), threadSegments(count = 2, next = 2))
        // Liste en préparation : rien n'est parcouru.
        assertEquals(listOf(n to a, a to n), threadSegments(count = 2, next = 0))
        assertEquals(listOf(n to n), threadSegments(count = 1, next = 0))
    }

    @Test
    fun reducedMotionDeclaresNoMovement() {
        assertNull(TicketMotion.reorder(reduced = true))
        assertNull(TicketMotion.fade<Float>(reduced = true))
        assertTrue(TicketMotion.reorder(reduced = false) != null)
    }

    private companion object {
        const val AA_TEXT = 4.5
        const val AA_GRAPHICS = 3.0
    }
}
