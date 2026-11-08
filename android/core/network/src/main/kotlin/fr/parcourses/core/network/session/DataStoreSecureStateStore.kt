package fr.parcourses.core.network.session

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.core.DataStoreFactory
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
import java.io.File
import java.io.IOException

/** [SecureStateStore] adossé à un DataStore dont le contenu est chiffré par Tink. */
class DataStoreSecureStateStore internal constructor(
    private val dataStore: DataStore<SecureState>,
) : SecureStateStore {
    override suspend fun read(): SecureState = readingErrors { dataStore.data.first() }

    override suspend fun update(transform: (SecureState) -> SecureState) {
        readingErrors { dataStore.updateData { transform(it) } }
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
            val aead = lazy(LazyThreadSafetyMode.SYNCHRONIZED) { keystoreAead(appContext) }
            return create(
                file = File(appContext.filesDir, "datastore/${SessionStorageFiles.DATASTORE_FILE}"),
                aead = { aead.value },
                scope = CoroutineScope(dispatcher + SupervisorJob()),
            )
        }

        internal fun create(
            file: File,
            aead: () -> Aead,
            scope: CoroutineScope,
        ): DataStoreSecureStateStore =
            DataStoreSecureStateStore(
                DataStoreFactory.create(
                    serializer = AeadStateSerializer(aead),
                    // Clé perdue (restauration, effacement des données du Keystore) : nouvelle session anonyme.
                    corruptionHandler = ReplaceFileCorruptionHandler { SecureState() },
                    scope = scope,
                    produceFile = { file },
                ),
            )

        private fun keystoreAead(context: Context): Aead {
            AeadConfig.register()
            val handle =
                AndroidKeysetManager
                    .Builder()
                    .withSharedPref(context, SessionStorageFiles.KEYSET_NAME, SessionStorageFiles.KEYSET_PREFS)
                    .withKeyTemplate(KeyTemplates.get("AES256_GCM"))
                    .withMasterKeyUri(SessionStorageFiles.MASTER_KEY_URI)
                    .build()
                    .keysetHandle
            return handle.getPrimitive(RegistryConfiguration.get(), Aead::class.java)
        }
    }
}
