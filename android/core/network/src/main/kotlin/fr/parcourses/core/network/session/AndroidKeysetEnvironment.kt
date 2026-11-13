package fr.parcourses.core.network.session

import android.content.Context
import android.os.UserManager
import com.google.crypto.tink.Aead
import com.google.crypto.tink.BinaryKeysetReader
import com.google.crypto.tink.InsecureSecretKeyAccess
import com.google.crypto.tink.KeyTemplates
import com.google.crypto.tink.LegacyKeysetSerialization
import com.google.crypto.tink.RegistryConfiguration
import com.google.crypto.tink.aead.AeadConfig
import com.google.crypto.tink.integration.android.AndroidKeysetManager
import com.google.crypto.tink.integration.android.AndroidKeystoreKmsClient
import com.google.crypto.tink.subtle.Hex
import java.io.File
import java.security.KeyStore

/** Accès à l'alias de la clé maîtresse, séparé pour simuler un Keystore qui répond mal. */
internal interface MasterKeyAliases {
    fun contains(alias: String): Boolean

    fun delete(alias: String)
}

/** L'Android Keystore : une instance neuve à chaque appel, pour ne pas relire un état mis en cache. */
internal object AndroidKeyStoreAliases : MasterKeyAliases {
    override fun contains(alias: String): Boolean = androidKeyStore().containsAlias(alias)

    override fun delete(alias: String) {
        val keyStore = androidKeyStore()
        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
    }

    private fun androidKeyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
}

/** [KeysetEnvironment] réel : préférences Tink et Android Keystore. */
internal class AndroidKeysetEnvironment(
    private val context: Context,
    private val aliases: MasterKeyAliases = AndroidKeyStoreAliases,
    /** Attente avant de confirmer l'absence de l'alias. */
    private val pause: (Long) -> Unit = Thread::sleep,
) : KeysetEnvironment {
    private val prefs get() = context.getSharedPreferences(SessionStorageFiles.KEYSET_PREFS, Context.MODE_PRIVATE)

    override fun checkAvailable() {
        // Stockage chiffré par l'appareil pas encore déverrouillé (démarrage direct) : le jeu de clés
        // paraîtrait absent et une nouvelle clé serait créée à tort.
        val users = context.getSystemService(UserManager::class.java)
        if (users != null && !users.isUserUnlocked) throw SecureStorageUnavailableException("Appareil verrouillé")
    }

    override fun keysetExists(): Boolean {
        if (prefs.contains(SessionStorageFiles.KEYSET_NAME)) return true
        // Le fichier n'est créé qu'à l'écriture du jeu de clés (`commit`) et supprimé avec lui : présent mais vide
        // à la lecture, il n'a pas été lu (avant Android 9, un XML illisible donne des préférences vides).
        if (keysetPrefsFiles().any(File::exists)) {
            throw SecureStorageUnavailableException("Préférences du jeu de clés illisibles")
        }
        return false
    }

    @Suppress("TooGenericExceptionCaught")
    override fun masterKeyState(): MasterKeyState =
        try {
            if (aliases.contains(SessionStorageFiles.MASTER_KEY_ALIAS)) {
                MasterKeyState.Present
            } else {
                // Un Keystore qui démarre peut répondre « absent » : l'absence n'est une preuve que confirmée
                // par une seconde lecture, un peu plus tard.
                pause(ABSENCE_CONFIRMATION_DELAY_MS)
                if (aliases.contains(SessionStorageFiles.MASTER_KEY_ALIAS)) {
                    MasterKeyState.Unreachable(IllegalStateException("Alias apparu entre deux lectures"))
                } else {
                    MasterKeyState.Absent
                }
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

    @Suppress("TooGenericExceptionCaught")
    override fun keysetProtection(): KeysetProtection {
        val stored =
            try {
                Hex.decode(prefs.getString(SessionStorageFiles.KEYSET_NAME, null) ?: error("Jeu de clés absent"))
            } catch (e: Exception) {
                return KeysetProtection.Unverifiable(e)
            }
        val failure = decryptionFailure(stored)
        return when {
            failure == null -> KeysetProtection.Encrypted
            readsInCleartext(stored) -> KeysetProtection.Cleartext
            else -> KeysetProtection.Unverifiable(failure)
        }
    }

    /** `null` si [stored] se déchiffre avec la clé maîtresse, sinon l'erreur rencontrée. */
    @Suppress("TooGenericExceptionCaught")
    private fun decryptionFailure(stored: ByteArray): Exception? =
        try {
            // Même clé maîtresse, même format que `AndroidKeysetManager` (données associées vides).
            val master = AndroidKeystoreKmsClient().getAead(SessionStorageFiles.MASTER_KEY_URI)
            LegacyKeysetSerialization.parseEncryptedKeyset(BinaryKeysetReader.withBytes(stored), master, ByteArray(0))
            null
        } catch (e: Exception) {
            e
        }

    @Suppress("TooGenericExceptionCaught", "SwallowedException")
    private fun readsInCleartext(stored: ByteArray): Boolean =
        try {
            LegacyKeysetSerialization.parseKeyset(BinaryKeysetReader.withBytes(stored), InsecureSecretKeyAccess.get())
            true
        } catch (e: Exception) {
            // Un jeu de clés chiffré ne se lit pas en clair : c'est le cas attendu.
            false
        }

    override fun deleteKeyset() {
        context.deleteSharedPreferences(SessionStorageFiles.KEYSET_PREFS)
        // Un jeu de clés resté sur le disque (en clair, ou face à une clé maîtresse effacée) ne doit pas passer
        // pour supprimé.
        if (keysetPrefsFiles().any(File::exists)) throw SecureStorageUnavailableException("Jeu de clés non effacé")
    }

    override fun deleteMasterKey() {
        aliases.delete(SessionStorageFiles.MASTER_KEY_ALIAS)
    }

    /** `shared_prefs/<nom>.xml` et sa copie de secours, que `SharedPreferences` restaure au chargement. */
    private fun keysetPrefsFiles(): List<File> {
        val directory = File(context.dataDir, "shared_prefs")
        val name = "${SessionStorageFiles.KEYSET_PREFS}.xml"
        return listOf(File(directory, name), File(directory, "$name.bak"))
    }

    private companion object {
        const val ABSENCE_CONFIRMATION_DELAY_MS = 250L
    }
}
