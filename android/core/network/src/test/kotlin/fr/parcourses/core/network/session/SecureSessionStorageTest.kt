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
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
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

    /** Horloge monotone des tests : seule la durée d'une série d'échecs compte. */
    private var clock = 0L

    private fun storeFrom(
        file: File,
        source: AeadSource,
        keys: SessionKeys = SessionKeys.None,
    ): DataStoreSecureStateStore {
        val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
        scopes += scope
        return DataStoreSecureStateStore.create(
            file,
            File(file.parentFile, file.name + ".account"),
            source,
            scope,
            keys = keys,
            io = Dispatchers.Unconfined,
            monotonicMillis = { clock },
        )
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
    fun aSignOutWaitsForARefreshAlreadyWritingAndIsNotUndoneByIt() =
        runBlocking {
            val aead = newAead()
            val state = store(File(folder.root, "o.pb")) { aead }
            val manager = EncryptedSessionManager(state)
            manager.saveSession(session)
            val refreshed = session.copy(accessToken = "refreshed-secret-token")

            // Vraie course sur deux fils : le rafraîchissement tient le verrou, la déconnexion arrive pendant.
            val refreshing = CountDownLatch(1)
            val release = CountDownLatch(1)
            val refresh =
                launch(Dispatchers.Default) {
                    state.update {
                        refreshing.countDown()
                        release.await()
                        it.copy(session = refreshed)
                    }
                }
            val signOut: Job
            val signedOutEarly: Boolean
            try {
                assertTrue(refreshing.await(5, TimeUnit.SECONDS))
                signOut = launch(Dispatchers.Default) { manager.deleteSession() }
                // Sans verrou, la déconnexion écrirait tout de suite, puis le rafraîchissement la défairait.
                delay(200)
                signedOutEarly = signOut.isCompleted
            } finally {
                // Toujours libérer le rafraîchissement : sinon un échec bloquerait `runBlocking` pour toujours.
                release.countDown()
            }
            joinAll(refresh, signOut)
            assertFalse("la déconnexion n'attend pas le rafraîchissement en cours", signedOutEarly)
            assertNull(state.read().session)
        }

    @Test
    fun repeatedKeyFailuresOverTimeMarkTheStorageStuckUntilTheKeyOpens() =
        runBlocking {
            val file = File(folder.root, "stuck.pb")
            val aead = newAead()
            EncryptedSessionManager(store(file) { aead }).saveSession(session)
            restart()

            var keyAvailable = false
            val state = store(file) { if (keyAvailable) aead else throw SecureStorageUnavailableException("key") }
            // Plusieurs échecs d'affilée, mais dans la même seconde : une panne passagère.
            repeat(KeyAccessMonitor.STUCK_AFTER_FAILURES + 2) { runCatching { state.read() } }
            assertFalse(state.isStuck.value)
            clock += KeyAccessMonitor.STUCK_AFTER_MILLIS
            runCatching { state.read() }
            assertTrue(state.isStuck.value)

            keyAvailable = true
            assertEquals(session, state.read().session)
            assertFalse(state.isStuck.value)
        }

    @Test
    fun readingAnEmptyFileSaysNothingAboutTheKey() =
        runBlocking {
            // Premier lancement : la lecture réussit sans clé, l'écriture échoue. Le compteur ne repart pas à zéro.
            val state = store(File(folder.root, "empty.pb")) { throw SecureStorageUnavailableException("key") }
            repeat(KeyAccessMonitor.STUCK_AFTER_FAILURES) {
                state.read()
                runCatching { state.checkWritable() }
                clock += KeyAccessMonitor.STUCK_AFTER_MILLIS
            }
            assertTrue(state.isStuck.value)
        }

    /** Session enregistrée, puis la clé ne s'ouvre plus sans preuve de corruption : rien n'est effacé. */
    private fun stuckStore(file: File): Pair<DataStoreSecureStateStore, FakeKeysetEnvironment> {
        val env = FakeKeysetEnvironment()
        runBlocking { storeFrom(file, KeystoreAeadSource(env)).update { SecureState(session, "account-1") } }
        restart()
        val stuckKey =
            object : KeysetEnvironment by env {
                override fun build(): Aead =
                    if (env.keysetDeletions == 0) throw GeneralSecurityException("?") else env.build()
            }
        val source = KeystoreAeadSource(stuckKey)
        return storeFrom(file, source, keys = source) to env
    }

    @Test
    fun resettingAStuckSessionStartsOverAndKeepsTheKnownAccount() =
        runBlocking {
            val file = File(folder.root, "datastore/reset.pb")
            val (state, env) = stuckStore(file)
            repeat(KeyAccessMonitor.STUCK_AFTER_FAILURES) {
                runCatching { state.read() }
                clock += KeyAccessMonitor.STUCK_AFTER_MILLIS
            }
            assertTrue(state.isStuck.value)
            assertFalse(env.erased)

            assertTrue(state.resetSession())

            assertFalse(state.isStuck.value)
            assertEquals(SecureState(null, "account-1"), state.read())
            assertEquals(1, env.keysetDeletions)
            assertEquals(1, env.masterKeyDeletions)
            // La nouvelle clé chiffre la suite : une session enregistrée se relit après un redémarrage.
            EncryptedSessionManager(state).saveSession(session)
            restart()
            assertEquals(session, EncryptedSessionManager(storeFrom(file, KeystoreAeadSource(env))).loadSession())
        }

    @Test
    fun aResetDestroysNothingOnceTheKeyOpensAgain() =
        runBlocking {
            val file = File(folder.root, "healthy.pb")
            val env = FakeKeysetEnvironment()
            val source = KeystoreAeadSource(env)
            val state = storeFrom(file, source, keys = source)
            state.update { SecureState(session, "account-1") }
            assertFalse(state.resetSession())
            assertFalse(env.erased)
            assertEquals(SecureState(session, "account-1"), state.read())
        }

    @Test
    fun anEmptyFileIsNotWritableWithoutItsKey() =
        runBlocking<Unit> {
            // Premier lancement : rien à lire, donc la lecture seule ne touche jamais la clé.
            val state = store(File(folder.root, "empty.pb")) { throw SecureStorageUnavailableException("key") }
            assertNull(state.read().session)
            assertThrows(SecureStorageUnavailableException::class.java) {
                runBlocking { state.checkWritable() }
            }
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
