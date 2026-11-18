package fr.parcourses.core.data.attestation

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.DataTest
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.sync.InMemorySyncCursors
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** État de l'attestation (#137) sur le disque : par compte, un seul compte gardé, effacé par la purge locale. */
@RunWith(AndroidJUnit4::class)
class AttestationStoreTest : DataTest() {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val first = Uuid.parse("aaaaaaaa-0000-4000-8000-000000000001")
    private val second = Uuid.parse("bbbbbbbb-0000-4000-8000-000000000002")
    private val due = Instant.fromEpochMilliseconds(1_763_463_600_123)

    @Test
    fun theStateSurvivesARelaunchUnderItsAccount() {
        SharedPreferencesAttestationStore(context).write(first, AttestationState(AttestationStatus.Pending, due))

        val relaunched = SharedPreferencesAttestationStore(context)
        assertEquals(AttestationState(AttestationStatus.Pending, due), relaunched.read(first))
        assertNull(relaunched.read(second))
        // Le fichier est celui que les règles de sauvegarde excluent.
        val raw = context.getSharedPreferences("device_attestation", Context.MODE_PRIVATE)
        assertEquals("pending", raw.getString("attestation.$first.status", null))
        assertEquals(due.toEpochMilliseconds(), raw.getLong("attestation.$first.nextAttemptAt", 0))
    }

    @Test
    fun aFinalStateHasNoDueDateAndReplacesTheOtherAccounts() {
        val store = SharedPreferencesAttestationStore(context)
        store.write(first, AttestationState(AttestationStatus.Pending, due))
        store.write(second, AttestationState(AttestationStatus.Attested, null))

        assertEquals(AttestationState(AttestationStatus.Attested, null), store.read(second))
        assertNull(store.read(first))
        assertEquals(setOf("attestation.$second.status"), prefs().all.keys)
    }

    @Test
    fun anUnknownStatusCountsAsNoState() {
        prefs().edit().putString("attestation.$first.status", "future").commit()

        assertNull(SharedPreferencesAttestationStore(context).read(first))
    }

    @Test
    fun theLocalPurgeClearsTheState() =
        runBlocking {
            val store = SharedPreferencesAttestationStore(context)
            store.write(first, AttestationState(AttestationStatus.Unsupported, null))

            LocalDataPurge(db, InMemorySyncCursors(), attestation = store).run()

            assertNull(store.read(first))
            assertEquals(emptySet<String>(), prefs().all.keys)
        }

    private fun prefs() = context.getSharedPreferences(SharedPreferencesAttestationStore.FILE, Context.MODE_PRIVATE)
}
