package fr.parcourses.core.data

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountDeletionMarker
import fr.parcourses.core.data.account.AccountDeletionPhase
import fr.parcourses.core.data.account.SharedPreferencesAccountDeletionFlag
import fr.parcourses.core.data.sync.SharedPreferencesSyncCursors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Drapeau `account.deletion` et curseurs : ce que la suppression du compte (#68) écrit sur le disque. */
@RunWith(AndroidJUnit4::class)
class AccountDeletionFlagTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun theFlagSurvivesARelaunchWithItsPhaseAndAccount() {
        val account = Uuid.random().toString()
        val attempt = Instant.fromEpochMilliseconds(1_763_000_000_123)
        val marker = AccountDeletionMarker(AccountDeletionPhase.ServerDeleted, account, attempt)
        SharedPreferencesAccountDeletionFlag(context).write(marker)

        val relaunched = SharedPreferencesAccountDeletionFlag(context)
        assertTrue(relaunched.isPending)
        assertEquals(marker, relaunched.read())
        // Le fichier et la clé sont ceux que les règles de sauvegarde excluent.
        val raw =
            context
                .getSharedPreferences("account_deletion", Context.MODE_PRIVATE)
                .getString("account.deletion", null)
        assertEquals("serverDeleted:1763000000123:$account", raw)

        relaunched.clear()
        assertFalse(SharedPreferencesAccountDeletionFlag(context).isPending)
    }

    @Test
    fun aFlagWithoutAccountOrWithAnUnknownPhaseRestartsFromTheBeginning() {
        val flag = SharedPreferencesAccountDeletionFlag(context)
        flag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, null))
        assertEquals(AccountDeletionMarker(AccountDeletionPhase.Requested, null, null), flag.read())

        val prefs = context.getSharedPreferences("account_deletion", Context.MODE_PRIVATE)
        prefs.edit().putString("account.deletion", "laterPhase:12:abc").commit()
        assertEquals(
            AccountDeletionMarker(AccountDeletionPhase.Requested, "abc", Instant.fromEpochMilliseconds(12)),
            flag.read(),
        )
        // Tentative illisible : tenue pour faite, un refus ne sera pas cru sur parole.
        prefs.edit().putString("account.deletion", "requested:x:abc").commit()
        assertEquals(Instant.fromEpochMilliseconds(0), flag.read()?.lastAttemptAt)
    }

    @Test
    fun clearingTheCursorsForgetsTheAccountToo() {
        val cursors = SharedPreferencesSyncCursors(context)
        cursors.accountId = Uuid.random()
        cursors.lists = Instant.fromEpochSeconds(1)
        cursors.items = Instant.fromEpochSeconds(2)
        cursors.catalog = Instant.fromEpochSeconds(3)

        cursors.clear()

        val relaunched = SharedPreferencesSyncCursors(context)
        assertNull(relaunched.accountId)
        assertNull(relaunched.lists)
        assertNull(relaunched.items)
        assertNull(relaunched.catalog)
    }
}
