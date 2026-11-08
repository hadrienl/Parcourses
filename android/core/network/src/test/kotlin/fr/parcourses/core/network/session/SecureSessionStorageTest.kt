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
import kotlinx.coroutines.launch
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
    ): DataStoreSecureStateStore = storeFrom(file, AeadSource { aead() })

    private fun storeFrom(
        file: File,
        source: AeadSource,
    ): DataStoreSecureStateStore {
        val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
        scopes += scope
        return DataStoreSecureStateStore.create(file, File(file.parentFile, file.name + ".account"), source, scope)
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

            val locked = store(file) { throw SecureStorageUnavailableException("keystore locked") }
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

    @Test
    fun concurrentUpdatesAreNotLost() =
        runTest {
            val state =
                store(File(folder.root, "s.pb")) { newAead() }.let { s ->
                    val aead = newAead()
                    store(File(folder.root, "c.pb")) { aead }
                }
            state.update { it.copy(lastAccountId = "0") }
            kotlinx.coroutines.coroutineScope {
                repeat(100) {
                    launch(Dispatchers.Default) {
                        state.update { it.copy(lastAccountId = (it.lastAccountId!!.toInt() + 1).toString()) }
                    }
                }
            }
            assertEquals("100", state.read().lastAccountId)
        }

    @Test
    fun aSignOutIsNotUndoneByALateRefreshOfTheSameSnapshotOrder() =
        runTest {
            val aead = newAead()
            val state = store(File(folder.root, "o.pb")) { aead }
            val manager = EncryptedSessionManager(state)
            manager.saveSession(session)
            manager.deleteSession()
            // Chaque opération est atomique : la dernière écrite gagne, sans état mélangé.
            assertNull(state.read().session)
        }

    @Test
    fun theKnownAccountIsStoredApartFromTheSession() =
        runTest {
            val file = File(folder.root, "s.pb")
            val aead = newAead()
            store(file) { aead }.update { it.copy(session = session, lastAccountId = "account-123") }
            val marker = File(folder.root, "s.pb.account").readText()
            assertTrue(marker.contains("account-123"))
            assertFalse(marker.contains("secret-token"))
            assertFalse(String(file.readBytes(), Charsets.ISO_8859_1).contains("account-123"))
        }

    @Test
    fun tokensNeverReachToString() {
        val text = SecureState(session, "acc").toString()
        assertFalse(text.contains("secret-token"))
        assertTrue(text.contains("acc"))
    }
}
