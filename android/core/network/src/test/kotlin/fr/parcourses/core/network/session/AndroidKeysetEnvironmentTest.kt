package fr.parcourses.core.network.session

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.google.crypto.tink.InsecureSecretKeyAccess
import com.google.crypto.tink.KeyTemplates
import com.google.crypto.tink.KeysetHandle
import com.google.crypto.tink.TinkProtoKeysetFormat
import com.google.crypto.tink.aead.AeadConfig
import com.google.crypto.tink.subtle.Hex
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/** Simule l'alias de la clé maîtresse : une réponse par lecture, la dernière se répète. */
private class ScriptedAliases(
    vararg answers: Boolean,
) : MasterKeyAliases {
    private val answers = answers.toMutableList()
    var reads = 0
    var deletions = 0

    override fun contains(alias: String): Boolean {
        reads++
        return if (answers.size > 1) answers.removeAt(0) else answers.first()
    }

    override fun delete(alias: String) {
        deletions++
    }
}

/**
 * Preuves de perte de [AndroidKeysetEnvironment] sur de vraies préférences (Robolectric). Robolectric n'a pas
 * d'Android Keystore : Tink y écrit donc le jeu de clés **en clair**, exactement le cas résiduel de #51.
 */
@RunWith(RobolectricTestRunner::class)
class AndroidKeysetEnvironmentTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val prefsFile get() = File(context.dataDir, "shared_prefs/${SessionStorageFiles.KEYSET_PREFS}.xml")

    @Before
    fun clean() {
        context.deleteSharedPreferences(SessionStorageFiles.KEYSET_PREFS)
    }

    private fun environment(aliases: MasterKeyAliases = ScriptedAliases(true)) =
        AndroidKeysetEnvironment(context, aliases, pause = {})

    @Test
    fun noPrefsFileIsAFirstLaunch() {
        assertFalse(environment().keysetExists())
    }

    @Test
    fun aPrefsFileThatReadsEmptyIsNotAFirstLaunch() {
        // Fichier présent mais lu sans le jeu de clés (avant Android 9, un XML illisible donne des préférences vides).
        prefsFile.parentFile!!.mkdirs()
        prefsFile.writeText("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map />\n")
        assertThrows(SecureStorageUnavailableException::class.java) { environment().keysetExists() }
    }

    @Test
    fun aStoredKeysetExists() {
        context
            .getSharedPreferences(SessionStorageFiles.KEYSET_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(SessionStorageFiles.KEYSET_NAME, "00")
            .commit()
        assertTrue(environment().keysetExists())
    }

    @Test
    fun anAliasMissingOnlyOnceIsNotALoss() {
        // Keystore qui démarre : « absent », puis « présent ».
        val aliases = ScriptedAliases(false, true)
        val state = environment(aliases).masterKeyState()
        assertTrue(state.toString(), state is MasterKeyState.Unreachable)
        assertEquals(2, aliases.reads)
    }

    @Test
    fun anAliasMissingTwiceIsALoss() {
        assertEquals(MasterKeyState.Absent, environment(ScriptedAliases(false)).masterKeyState())
    }

    @Test
    fun aKeystoreThatThrowsIsUnreachable() {
        val failing =
            object : MasterKeyAliases {
                override fun contains(alias: String): Boolean = throw java.security.KeyStoreException("not ready")

                override fun delete(alias: String) = Unit
            }
        assertTrue(environment(failing).masterKeyState() is MasterKeyState.Unreachable)
    }

    @Test
    fun aKeysetStoredInClearIsDetected() {
        AeadConfig.register()
        val handle = KeysetHandle.generateNew(KeyTemplates.get("AES256_GCM"))
        val clear = TinkProtoKeysetFormat.serializeKeyset(handle, InsecureSecretKeyAccess.get())
        context
            .getSharedPreferences(SessionStorageFiles.KEYSET_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(SessionStorageFiles.KEYSET_NAME, Hex.encode(clear))
            .commit()
        assertEquals(KeysetProtection.Cleartext, environment().keysetProtection())
    }

    @Test
    fun anUnreadableKeysetIsUnverifiableNotCleartext() {
        context
            .getSharedPreferences(SessionStorageFiles.KEYSET_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(SessionStorageFiles.KEYSET_NAME, "0102030405")
            .commit()
        assertTrue(environment().keysetProtection() is KeysetProtection.Unverifiable)
    }

    @Test
    fun tinkFallingBackToCleartextIsNeverAccepted() {
        // Bout à bout avec le vrai `AndroidKeysetManager` : sans Keystore utilisable, il écrit le jeu de clés en
        // clair alors que l'alias passe pour présent. Avant #51, cet Aead était accepté et le resterait ensuite.
        val source = KeystoreAeadSource(environment(ScriptedAliases(true)))
        assertThrows(SecureStorageUnavailableException::class.java) { source.get() }
        assertFalse(prefsFile.exists())
    }
}
