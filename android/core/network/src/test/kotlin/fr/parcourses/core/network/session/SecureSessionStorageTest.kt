@file:Suppress("ktlint:standard:max-line-length")

package fr.parcourses.core.network.session

import com.google.crypto.tink.Aead
import com.google.crypto.tink.KeyTemplates
import com.google.crypto.tink.KeysetHandle
import com.google.crypto.tink.RegistryConfiguration
import com.google.crypto.tink.aead.AeadConfig
import io.github.jan.supabase.auth.exception.NoSessionFoundException
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.GeneralSecurityException
import kotlin.time.Instant

class SecureSessionStorageTest {
    @get:Rule
    val folder = TemporaryFolder()

    private fun newAead(): Aead {
        AeadConfig.register()
        return KeysetHandle
            .generateNew(
                KeyTemplates.get("AES256_GCM"),
            ).getPrimitive(RegistryConfiguration.get(), Aead::class.java)
    }

    private val scopes = mutableListOf<CoroutineScope>()

    /** Un seul DataStore actif par fichier : [restart] ferme les précédents, comme un nouveau processus. */
    private fun store(
        file: File,
        aead: () -> Aead,
    ): DataStoreSecureStateStore {
        val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
        scopes += scope
        return DataStoreSecureStateStore.create(file, aead, scope)
    }

    private fun restart() {
        scopes.forEach { it.cancel() }
        scopes.clear()
    }

    @After
    fun closeStores() = restart()

    private val session =
        UserSession(
            accessToken = "access-secret-token",
            refreshToken = "refresh-secret-token",
            expiresIn = 3600,
            tokenType = "bearer",
            expiresAt = Instant.fromEpochSeconds(1_900_000_000),
        )

    @Test
    fun sessionSurvivesARestartAndIsNeverWrittenInClear() =
        runTest {
            val file = File(folder.root, "datastore/state.pb")
            val aead = newAead()
            EncryptedSessionManager(store(file) { aead }).saveSession(session)

            val onDisk = file.readBytes()
            assertTrue(onDisk.isNotEmpty())
            assertFalse(String(onDisk, Charsets.ISO_8859_1).contains("secret-token"))
            assertFalse(String(onDisk, Charsets.ISO_8859_1).contains("access_token"))

            // « Redémarrage » : un nouveau DataStore sur le même fichier, avec la même clé.
            restart()
            val restarted = EncryptedSessionManager(store(file) { aead })
            assertEquals(session, restarted.loadSession())
        }

    @Test
    fun noSessionMeansNoSessionFound() =
        runTest {
            val manager = EncryptedSessionManager(store(File(folder.root, "s.pb")) { newAead() })
            assertThrows(
                NoSessionFoundException::class.java,
            ) { kotlinx.coroutines.runBlocking { manager.loadSession() } }
            assertNull(manager.loadSessionOrNull())
        }

    @Test
    fun deletingTheSessionKeepsTheLastKnownAccount() =
        runTest {
            val aead = newAead()
            val state = store(File(folder.root, "s.pb")) { aead }
            val manager = EncryptedSessionManager(state)
            manager.saveSession(session)
            state.update { it.copy(lastAccountId = "acc") }
            manager.deleteSession()
            assertNull(state.read().session)
            assertEquals("acc", state.read().lastAccountId)
        }

    @Test
    fun aLostKeyStartsOverInsteadOfCrashing() =
        runTest {
            val file = File(folder.root, "s.pb")
            val first = newAead()
            EncryptedSessionManager(store(file) { first }).saveSession(session)
            restart()
            // Autre clé (clé maîtresse du Keystore perdue) : fichier illisible, remplacé par un état vide.
            val second = newAead()
            val other = EncryptedSessionManager(store(file) { second })
            assertNull(other.loadSessionOrNull())
        }

    @Test
    fun anUnavailableKeystoreNeverErasesTheSession() =
        runTest {
            val file = File(folder.root, "s.pb")
            val aead = newAead()
            EncryptedSessionManager(store(file) { aead }).saveSession(session)
            val before = file.readBytes()
            restart()

            val locked = store(file) { throw GeneralSecurityException("keystore locked") }
            assertThrows(
                SecureStorageUnavailableException::class.java,
            ) { kotlinx.coroutines.runBlocking { locked.read() } }
            assertArrayEquals(before, file.readBytes())

            // La clé revient : la session est intacte.
            restart()
            assertEquals(session, EncryptedSessionManager(store(file) { aead }).loadSession())
        }

    @Test
    fun theFileIsBoundToItsPurpose() =
        runTest {
            val aead = newAead()
            val cipher = aead.encrypt("{}".toByteArray(), "autre usage".toByteArray())
            val file = File(folder.root, "s.pb").also { it.writeBytes(cipher) }
            // Même clé, autres données associées : refusé (corruption), donc état vide.
            assertNull(EncryptedSessionManager(store(file) { aead }).loadSessionOrNull())
        }
}
