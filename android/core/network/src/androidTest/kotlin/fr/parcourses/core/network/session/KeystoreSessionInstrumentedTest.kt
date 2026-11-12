package fr.parcourses.core.network.session

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.crypto.tink.InsecureSecretKeyAccess
import com.google.crypto.tink.KeyTemplates
import com.google.crypto.tink.KeysetHandle
import com.google.crypto.tink.TinkProtoKeysetFormat
import com.google.crypto.tink.aead.AeadConfig
import com.google.crypto.tink.subtle.Hex
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.time.Instant

/**
 * [AndroidKeysetEnvironment] et [KeystoreAeadSource] sur le **vrai** Android Keystore (#51) : ce que les tests
 * unitaires simulent (exceptions levées, jeu de clés chiffré ou non) est vérifié ici sur un appareil.
 * `./gradlew :core:network:connectedDebugAndroidTest`
 */
@RunWith(AndroidJUnit4::class)
class KeystoreSessionInstrumentedTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val prefs get() = context.getSharedPreferences(SessionStorageFiles.KEYSET_PREFS, Context.MODE_PRIVATE)

    private fun environment() = AndroidKeysetEnvironment(context)

    private fun storedKeyset(): String = prefs.getString(SessionStorageFiles.KEYSET_NAME, null)!!

    private fun store(keyset: String) {
        assertTrue(prefs.edit().putString(SessionStorageFiles.KEYSET_NAME, keyset).commit())
    }

    @Before
    @After
    fun clean() {
        val env = environment()
        env.deleteKeyset()
        env.deleteMasterKey()
    }

    @Test
    fun theFirstKeysetIsEncryptedByTheMasterKey() {
        val env = environment()
        val aead = KeystoreAeadSource(env).get()
        assertEquals(MasterKeyState.Present, env.masterKeyState())
        assertEquals(KeysetProtection.Encrypted, env.keysetProtection())
        // « Relance » : même clé.
        val again = KeystoreAeadSource(environment()).get()
        assertEquals("x", String(again.decrypt(aead.encrypt("x".toByteArray(), null), null)))
    }

    @Test
    fun aKeysetInClearIsReplacedByAnEncryptedOne() {
        KeystoreAeadSource(environment()).get()
        AeadConfig.register()
        val clear =
            TinkProtoKeysetFormat.serializeKeyset(
                KeysetHandle.generateNew(KeyTemplates.get("AES256_GCM")),
                InsecureSecretKeyAccess.get(),
            )
        store(Hex.encode(clear))
        val env = environment()
        assertEquals(KeysetProtection.Cleartext, env.keysetProtection())

        KeystoreAeadSource(env).get()
        assertNotEquals(Hex.encode(clear), storedKeyset())
        assertEquals(KeysetProtection.Encrypted, env.keysetProtection())
    }

    @Test
    fun aKeysetThatIsNotHexIsAProvenLoss() {
        KeystoreAeadSource(environment()).get()
        store("pas de l'hexadécimal")
        KeystoreAeadSource(environment()).get()
        assertEquals(KeysetProtection.Encrypted, environment().keysetProtection())
    }

    @Test
    fun aTamperedEncryptedKeysetIsAProvenLoss() {
        KeystoreAeadSource(environment()).get()
        val bytes = Hex.decode(storedKeyset())
        // Un octet du chiffré modifié : le Keystore refuse l'étiquette AES-GCM.
        bytes[bytes.size / 2] = (bytes[bytes.size / 2].toInt() xor 0x01).toByte()
        store(Hex.encode(bytes))
        val tampered = storedKeyset()
        KeystoreAeadSource(environment()).get()
        assertNotEquals(tampered, storedKeyset())
        assertEquals(KeysetProtection.Encrypted, environment().keysetProtection())
    }

    @Test
    fun aMissingMasterKeyIsAProvenLoss() {
        KeystoreAeadSource(environment()).get()
        environment().deleteMasterKey()
        assertEquals(MasterKeyState.Absent, environment().masterKeyState())
        KeystoreAeadSource(environment()).get()
        assertEquals(MasterKeyState.Present, environment().masterKeyState())
        assertEquals(KeysetProtection.Encrypted, environment().keysetProtection())
    }

    @Test
    fun destroyingTheKeysErasesBoth() {
        val source = KeystoreAeadSource(environment())
        source.get()
        source.destroy()
        assertFalse(environment().keysetExists())
        assertEquals(MasterKeyState.Absent, environment().masterKeyState())
    }

    @Test
    fun theSessionSurvivesARestartAndAResetKeepsAReadableKey() =
        runBlocking<Unit> {
            val directory = File(context.cacheDir, "keystore-session-test").apply { deleteRecursively() }
            val session =
                UserSession(
                    accessToken = "access-secret-token",
                    refreshToken = "refresh-secret-token",
                    expiresIn = 3600,
                    tokenType = "bearer",
                    expiresAt = Instant.fromEpochSeconds(1_900_000_000),
                )

            fun open(scope: CoroutineScope): DataStoreSecureStateStore {
                val source = KeystoreAeadSource(environment())
                return DataStoreSecureStateStore.create(
                    File(directory, "session.pb"),
                    File(directory, "account.json"),
                    source,
                    scope,
                    keys = source,
                )
            }

            val first = CoroutineScope(Dispatchers.IO + SupervisorJob())
            open(first).update { SecureState(session, "account-1") }
            // Un seul DataStore actif par fichier : le premier « processus » est arrêté avant le second.
            first.coroutineContext[Job]!!.cancelAndJoin()

            val second = CoroutineScope(Dispatchers.IO + SupervisorJob())
            val restarted = open(second)
            assertEquals(SecureState(session, "account-1"), restarted.read())
            // La clé s'ouvre : la réinitialisation ne détruit rien.
            assertFalse(restarted.resetSession())
            assertEquals(SecureState(session, "account-1"), restarted.read())
            second.coroutineContext[Job]!!.cancelAndJoin()
            directory.deleteRecursively()
        }
}
