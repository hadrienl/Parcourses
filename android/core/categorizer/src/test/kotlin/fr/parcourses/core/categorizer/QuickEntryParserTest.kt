package fr.parcourses.core.categorizer

import org.junit.Assert.assertEquals
import org.junit.Test

/** Mêmes cas que `QuickEntryParserTests` d'iOS : toute divergence doit être corrigée des deux côtés. */
class QuickEntryParserTest {
    private val parser = QuickEntryParser()

    private fun check(
        raw: String,
        quantity: String?,
        label: String,
    ) = assertEquals(raw, QuickEntry(quantity, label), parser.parse(raw))

    @Test
    fun separatesQuantityAndLabel() {
        check("2 laits demi-écrémé", "2", "laits demi-écrémé")
        check("lait", null, "lait")
        check("  pain   de  mie ", null, "pain de mie")
        check("1,5 kg de pommes", "1,5 kg", "pommes")
        check("0.5 L lait", "0.5 L", "lait")
        check("500g farine", "500g", "farine")
        check("2 paquets de pâtes", "2 paquets", "pâtes")
        check("2 boîtes d'ananas", "2 boîtes", "ananas")
        check("3 bouteilles d’eau", "3 bouteilles", "eau")
    }

    @Test
    fun understandsMultipliers() {
        check("6x33cl bière", "6x33cl", "bière")
        check("2x lait", "2x", "lait")
        check("2 x lait", "2", "lait")
        check("lait x2", "2", "lait")
        check("x2 lait", "2", "lait")
    }

    @Test
    fun neverLosesWhatWasTyped() {
        check("2", null, "2")
        check("1 kg", null, "1 kg")
        check("x2", null, "x2")
        check("", null, "")
        check("   ", null, "")
        check("1.2.3 truc", null, "1.2.3 truc")
        check("٣ tomates", null, "٣ tomates")
        check("de la farine", null, "de la farine")
        check("2,5kg", null, "2,5kg")
        check("1,5xyz lait", null, "1,5xyz lait")
    }

    @Test
    fun glueAndDecimalForms() {
        check("2,5kg pommes", "2,5kg", "pommes")
        check("1.5l lait", "1.5l", "lait")
    }

    @Test
    fun bareNumbersOverThreeDigitsStayInTheLabel() {
        check("1664 bière", null, "1664 bière")
        check("1664", null, "1664")
        check("100 clous", "100", "clous")
        check("1664 g farine", "1664 g", "farine")
    }

    @Test
    fun knownLimits() {
        check("3 Suisses", "3", "Suisses")
        check("2 d'accord", "2", "accord")
    }
}
