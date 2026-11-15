package fr.parcourses.core.data.account

import fr.parcourses.core.data.sync.AccountKind
import org.junit.Assert.assertEquals
import org.junit.Test

/** Bouton compte de l'écran Listes (#108) : mêmes cas qu’iOS. */
class AccountEntryTest {
    @Test
    fun anAnonymousAccountSignsIn() {
        assertEquals(AccountEntry.SignIn, AccountEntry.of(AccountKind.Anonymous, null))
        // Un prénom resté d'un ancien compte ne change rien.
        assertEquals(AccountEntry.SignIn, AccountEntry.of(AccountKind.Anonymous, "Hadrien"))
    }

    @Test
    fun anEmailAccountShowsTheInitialOfItsFirstName() {
        assertEquals(AccountEntry.Account("H"), AccountEntry.of(AccountKind.Email, "Hadrien"))
        assertEquals(AccountEntry.Account("L"), AccountEntry.of(AccountKind.Email, "  léa "))
    }

    @Test
    fun anEmailAccountWithoutAFirstNameHasNoInitial() {
        assertEquals(AccountEntry.Account(null), AccountEntry.of(AccountKind.Email, null))
        assertEquals(AccountEntry.Account(null), AccountEntry.of(AccountKind.Email, ""))
        assertEquals(AccountEntry.Account(null), AccountEntry.of(AccountKind.Email, " \t "))
    }

    @Test
    fun anAccentedInitialKeepsItsAccent() {
        assertEquals(AccountEntry.Account("É"), AccountEntry.of(AccountKind.Email, "élodie"))
    }
}
