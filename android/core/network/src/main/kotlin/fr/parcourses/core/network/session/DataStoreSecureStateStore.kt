package fr.parcourses.core.network.session

import android.content.Context
import android.os.UserManager
import androidx.datastore.core.DataStore
import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.Serializer
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import com.google.crypto.tink.Aead
import com.google.crypto.tink.KeyTemplates
import com.google.crypto.tink.RegistryConfiguration
import com.google.crypto.tink.aead.AeadConfig
import com.google.crypto.tink.integration.android.AndroidKeysetManager
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.KeyStore

/**
 * [SecureStateStore] sur deux DataStore :
 * - la session, **chiffrée** par Tink ;
 * - le dernier compte connu, **en clair** (voir [AccountMarker]) : il doit survivre à une clé perdue pour que le
 *   changement de compte soit détecté au lieu d'être adopté en silence.
 */
class DataStoreSecureStateStore internal constructor(
    private val sessions: DataStore<SessionHolder>,
    private val accounts: DataStore<AccountMarker>,
) : SecureStateStore {
    override suspend fun read(): SecureState =
        readingErrors { SecureState(sessions.data.first().session, accounts.data.first().lastAccountId) }

    override suspend fun update(transform: (SecureState) -> SecureState) {
        readingErrors {
            val before = read()
            val after = transform(before)
            if (after.session != before.session) sessions.updateData { SessionHolder(after.session) }
            if (after.lastAccountId != before.lastAccountId) {
                accounts.updateData { AccountMarker(after.lastAccountId) }
            }
        }
    }

    private suspend inline fun <T> readingErrors(block: () -> T): T =
        try {
            block()
        } catch (e: SecureStorageUnavailableException) {
            throw e
        } catch (e: IOException) {
            throw SecureStorageUnavailableException("Stockage de session illisible", e)
        }

    companion object {
        /**
         * Clé AES-256-GCM générée une fois, stockée dans un jeu de clés Tink lui-même chiffré par une clé
         * maîtresse de l'Android Keystore. Aucune clé n'est jamais en clair sur le disque.
         */
        fun create(
            context: Context,
            dispatcher: CoroutineDispatcher = Dispatchers.IO,
        ): DataStoreSecureStateStore {
            val appContext = context.applicationContext
            val source = RecoveringAeadSource(build = { keystoreAead(appContext) }, reset = { resetKeys(appContext) })
            val aead = lazy(LazyThreadSafetyMode.SYNCHRONIZED) { source.get() }
            val directory = File(appContext.filesDir, "datastore")
            return create(
                sessionFile = File(directory, SessionStorageFiles.DATASTORE_FILE),
                accountFile = File(directory, SessionStorageFiles.ACCOUNT_FILE),
                aead = { aead.value },
                scope = CoroutineScope(dispatcher + SupervisorJob()),
            )
        }

        internal fun create(
            sessionFile: File,
            accountFile: File,
            aead: AeadSource,
            scope: CoroutineScope,
        ): DataStoreSecureStateStore =
            DataStoreSecureStateStore(
                DataStoreFactory.create(
                    serializer = AeadStateSerializer(aead),
                    // Clé perdue (restauration, effacement des données du Keystore) : nouvelle session anonyme.
                    corruptionHandler = ReplaceFileCorruptionHandler { SessionHolder() },
                    scope = scope,
                    produceFile = { sessionFile },
                ),
                DataStoreFactory.create(
                    serializer = AccountMarkerSerializer,
                    corruptionHandler = ReplaceFileCorruptionHandler { AccountMarker() },
                    scope = scope,
                    produceFile = { accountFile },
                ),
            )

        private fun keystoreAead(context: Context): Aead {
            // Stockage chiffré par l'appareil pas encore déverrouillé (démarrage direct) : le jeu de clés
            // paraîtrait absent et une nouvelle clé serait créée à tort.
            val users = context.getSystemService(UserManager::class.java)
            if (users != null && !users.isUserUnlocked) {
                throw SecureStorageUnavailableException("Appareil verrouillé")
            }
            AeadConfig.register()
            val handle =
                AndroidKeysetManager
                    .Builder()
                    .withSharedPref(context, SessionStorageFiles.KEYSET_NAME, SessionStorageFiles.KEYSET_PREFS)
                    .withKeyTemplate(KeyTemplates.get("AES256_GCM"))
                    .withMasterKeyUri(SessionStorageFiles.MASTER_KEY_URI)
                    .build()
                    .keysetHandle
            // Le jeu de clés doit être protégé par une clé du Keystore : jamais de repli silencieux en clair.
            if (!androidKeyStore().containsAlias(SessionStorageFiles.MASTER_KEY_ALIAS)) {
                throw SecureStorageUnavailableException("Clé maîtresse absente du Keystore")
            }
            return handle.getPrimitive(RegistryConfiguration.get(), Aead::class.java)
        }

        /** Efface le jeu de clés et la clé maîtresse : la session chiffrée avec eux est perdue. */
        private fun resetKeys(context: Context) {
            context.deleteSharedPreferences(SessionStorageFiles.KEYSET_PREFS)
            val keyStore = androidKeyStore()
            if (keyStore.containsAlias(SessionStorageFiles.MASTER_KEY_ALIAS)) {
                keyStore.deleteEntry(SessionStorageFiles.MASTER_KEY_ALIAS)
            }
        }

        private fun androidKeyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    }
}

internal object AccountMarkerSerializer : Serializer<AccountMarker> {
    private val json = Json { ignoreUnknownKeys = true }
    override val defaultValue = AccountMarker()

    override suspend fun readFrom(input: InputStream): AccountMarker {
        val bytes = input.readBytes()
        if (bytes.isEmpty()) return defaultValue
        return try {
            json.decodeFromString(AccountMarker.serializer(), bytes.decodeToString())
        } catch (e: SerializationException) {
            throw androidx.datastore.core.CorruptionException("Compte connu illisible", e)
        }
    }

    override suspend fun writeTo(
        t: AccountMarker,
        output: OutputStream,
    ) {
        output.write(json.encodeToString(AccountMarker.serializer(), t).encodeToByteArray())
    }
}
