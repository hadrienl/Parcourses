package fr.parcourses.core.network.session

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.Serializer
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

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
    // Lecture, transformation et écriture forment un tout : un rafraîchissement et une déconnexion en parallèle
    // ne doivent pas s'écraser (ni ressusciter une session supprimée).
    private val lock = Mutex()

    override suspend fun read(): SecureState = lock.withLock { readUnlocked() }

    private suspend fun readUnlocked(): SecureState =
        readingErrors { SecureState(sessions.data.first().session, accounts.data.first().lastAccountId) }

    override suspend fun update(transform: (SecureState) -> SecureState) {
        lock.withLock { updateUnlocked(transform) }
    }

    private suspend fun updateUnlocked(transform: (SecureState) -> SecureState) {
        readingErrors {
            val before = readUnlocked()
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
            val source = KeystoreAeadSource(AndroidKeysetEnvironment(appContext))
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
