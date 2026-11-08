package fr.parcourses.core.network.session

import com.google.crypto.tink.Aead
import com.google.crypto.tink.KeyTemplates
import com.google.crypto.tink.KeysetHandle
import com.google.crypto.tink.RegistryConfiguration
import com.google.crypto.tink.aead.AeadConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.InvalidKeyException
import java.security.KeyStoreException
import java.security.ProviderException
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException

/** Simule le Keystore et les préférences Tink : l'état survit d'un « lancement » à l'autre. */
internal class FakeKeysetEnvironment(
    var keyset: Aead? = null,
    var aliasPresent: Boolean = false,
    var keystoreError: Throwable? = null,
    var buildError: Throwable? = null,
    var buildCreatesAlias: Boolean = true,
) : KeysetEnvironment {
    var keysetDeletions = 0
    var masterKeyDeletions = 0

    override fun checkAvailable() = Unit

    override fun keysetExists() = keyset != null

    override fun masterKeyState(): MasterKeyState =
        keystoreError?.let { MasterKeyState.Unreachable(it) }
            ?: if (aliasPresent) MasterKeyState.Present else MasterKeyState.Absent

    override fun build(): Aead {
        buildError?.let { throw it }
        AeadConfig.register()
        val aead =
            keyset
                ?: KeysetHandle
                    .generateNew(KeyTemplates.get("AES256_GCM"))
                    .getPrimitive(RegistryConfiguration.get(), Aead::class.java)
        keyset = aead
        if (buildCreatesAlias) aliasPresent = true
        return aead
    }

    override fun deleteKeyset() {
        keyset = null
        keysetDeletions++
    }

    override fun deleteMasterKey() {
        aliasPresent = false
        masterKeyDeletions++
    }

    val erased get() = keysetDeletions + masterKeyDeletions > 0
}

class KeystoreAeadSourceTest {
    private fun existing() = FakeKeysetEnvironment().also { KeystoreAeadSource(it).get() }

    @Test
    fun firstUseCreatesAndKeepsTheKey() {
        val env = FakeKeysetEnvironment()
        val first = KeystoreAeadSource(env).get()
        assertNotNull(first)
        assertTrue(env.keysetExists() && env.aliasPresent)
        assertFalse(env.erased)
        // Même clé au lancement suivant.
        val again = KeystoreAeadSource(env).get()
        assertEquals("x", String(again.decrypt(first.encrypt("x".toByteArray(), null), null)))
    }

    @Test
    fun noUncertainFailureEverErasesTheKeys() {
        val failures =
            listOf(
                InvalidKeyException("invalidated"),
                UnrecoverableKeyException("unrecoverable"),
                KeyStoreException("keystore"),
                SecurityException("denied"),
                IllegalStateException("state"),
                IOException("prefs"),
                ProviderException("dead"),
                GeneralSecurityException("sans cause"),
                android.os.DeadObjectException(),
                GeneralSecurityException("enveloppe", InvalidKeyException("cause")),
            )
        for (failure in failures) {
            val env = existing().apply { buildError = failure }
            assertThrows(failure.toString(), SecureStorageUnavailableException::class.java) {
                KeystoreAeadSource(env).get()
            }
            assertFalse("effacé à tort sur $failure", env.erased)
            assertTrue(env.keysetExists())
        }
    }

    @Test
    fun anUnreachableKeystoreNeverErasesTheKeys() {
        val env = existing().apply { keystoreError = ProviderException("keystore dead") }
        assertThrows(SecureStorageUnavailableException::class.java) { KeystoreAeadSource(env).get() }
        assertFalse(env.erased)
    }

    @Test
    fun aMissingMasterKeyWithAKeysetIsAProvenLoss() {
        val env = existing().apply { aliasPresent = false }
        val old = env.keyset
        val fresh = KeystoreAeadSource(env).get()
        assertEquals(1, env.keysetDeletions)
        assertEquals(1, env.masterKeyDeletions)
        assertTrue(env.aliasPresent)
        assertFalse(old === env.keyset)
        assertNotNull(fresh)
    }

    @Test
    fun anUndecryptableKeysetWithAReachableKeystoreIsAProvenLoss() {
        for (proof in listOf<Throwable>(AEADBadTagException("bad tag"), IOException("wrap", AEADBadTagException()))) {
            val env = existing()
            var failures = 1
            val failing =
                object : KeysetEnvironment by env {
                    override fun build(): Aead = if (failures-- > 0) throw proof else env.build()
                }
            KeystoreAeadSource(failing).get()
            assertEquals(1, env.keysetDeletions)
        }
    }

    @Test
    fun corruptionIsNotProvenWhenTheKeystoreStopsAnswering() {
        val env = existing()
        val flaky =
            object : KeysetEnvironment by env {
                var calls = 0

                override fun masterKeyState(): MasterKeyState =
                    if (calls++ == 0) MasterKeyState.Present else MasterKeyState.Unreachable(ProviderException("gone"))

                override fun build(): Aead = throw AEADBadTagException("bad tag")
            }
        assertThrows(SecureStorageUnavailableException::class.java) { KeystoreAeadSource(flaky).get() }
        assertFalse(env.erased)
    }

    @Test
    fun aKeysetBuiltWithoutItsMasterKeyIsNeverLeftInClear() {
        val env = FakeKeysetEnvironment(buildCreatesAlias = false)
        assertThrows(SecureStorageUnavailableException::class.java) { KeystoreAeadSource(env).get() }
        assertFalse(env.keysetExists())
    }
}
