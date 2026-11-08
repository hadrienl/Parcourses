package fr.parcourses.core.network.session

import android.content.Context
import android.os.UserManager
import com.google.crypto.tink.Aead
import com.google.crypto.tink.KeyTemplates
import com.google.crypto.tink.RegistryConfiguration
import com.google.crypto.tink.aead.AeadConfig
import com.google.crypto.tink.integration.android.AndroidKeysetManager
import java.security.KeyStore

/** [KeysetEnvironment] réel : préférences Tink et Android Keystore. */
internal class AndroidKeysetEnvironment(
    private val context: Context,
) : KeysetEnvironment {
    private val prefs get() = context.getSharedPreferences(SessionStorageFiles.KEYSET_PREFS, Context.MODE_PRIVATE)

    override fun checkAvailable() {
        // Stockage chiffré par l'appareil pas encore déverrouillé (démarrage direct) : le jeu de clés
        // paraîtrait absent et une nouvelle clé serait créée à tort.
        val users = context.getSystemService(UserManager::class.java)
        if (users != null && !users.isUserUnlocked) throw SecureStorageUnavailableException("Appareil verrouillé")
    }

    override fun keysetExists(): Boolean = prefs.contains(SessionStorageFiles.KEYSET_NAME)

    @Suppress("TooGenericExceptionCaught")
    override fun masterKeyState(): MasterKeyState =
        try {
            val keyStore = androidKeyStore()
            if (keyStore.containsAlias(
                    SessionStorageFiles.MASTER_KEY_ALIAS,
                )
            ) {
                MasterKeyState.Present
            } else {
                MasterKeyState.Absent
            }
        } catch (e: Exception) {
            MasterKeyState.Unreachable(e)
        }

    override fun build(): Aead {
        AeadConfig.register()
        return AndroidKeysetManager
            .Builder()
            .withSharedPref(context, SessionStorageFiles.KEYSET_NAME, SessionStorageFiles.KEYSET_PREFS)
            .withKeyTemplate(KeyTemplates.get("AES256_GCM"))
            .withMasterKeyUri(SessionStorageFiles.MASTER_KEY_URI)
            .build()
            .keysetHandle
            .getPrimitive(RegistryConfiguration.get(), Aead::class.java)
    }

    override fun deleteKeyset() {
        context.deleteSharedPreferences(SessionStorageFiles.KEYSET_PREFS)
    }

    override fun deleteMasterKey() {
        val keyStore = androidKeyStore()
        if (keyStore.containsAlias(SessionStorageFiles.MASTER_KEY_ALIAS)) {
            keyStore.deleteEntry(SessionStorageFiles.MASTER_KEY_ALIAS)
        }
    }

    private fun androidKeyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
}
