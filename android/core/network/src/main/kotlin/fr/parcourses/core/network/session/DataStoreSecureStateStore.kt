package fr.parcourses.core.network.session

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.Serializer
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import com.google.crypto.tink.Aead
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.GeneralSecurityException

/**
 * [SecureStateStore] sur deux DataStore :
 * - la session, **chiffrée** par Tink ;
 * - le dernier compte connu, **en clair** (voir [AccountMarker]) : il doit survivre à une clé perdue pour que le
 *   changement de compte soit détecté au lieu d'être adopté en silence.
 */
class DataStoreSecureStateStore internal constructor(
    private val sessions: DataStore<SessionHolder>,
    private val accounts: DataStore<AccountMarker>,
    private val aead: KeyAccessMonitor,
    private val keys: SessionKeys = SessionKeys.None,
    /** Le Keystore et les préférences bloquent : jamais sur le fil de l'appelant (écran À propos). */
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : SecureStateStore {
    // Lecture, transformation et écriture forment un tout : un rafraîchissement et une déconnexion en parallèle
    // ne doivent pas s'écraser (ni ressusciter une session supprimée). Verrou non réentrant : voir [update].
    private val lock = Mutex()

    override val isStuck: StateFlow<Boolean> get() = aead.isStuck

    override suspend fun read(): SecureState = lock.withLock { readingErrors { readUnlocked() } }

    private suspend fun readUnlocked(): SecureState =
        SecureState(sessions.data.first().session, accounts.data.first().lastAccountId)

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

    override suspend fun checkWritable() {
        lock.withLock {
            readingErrors {
                readUnlocked()
                // Fichier encore vide (premier lancement) : la lecture n'a pas touché la clé. Le chiffrement, si.
                withContext(io) {
                    try {
                        aead.get().encrypt(ByteArray(0), AeadStateSerializer.ASSOCIATED_DATA)
                    } catch (e: GeneralSecurityException) {
                        throw SecureStorageUnavailableException("Chiffrement impossible", e)
                    }
                }
            }
        }
    }

    override suspend fun resetSession(): Boolean =
        lock.withLock {
            readingErrors {
                // La clé s'ouvre de nouveau (panne passée entre l'affichage et la confirmation) : rien à détruire,
                // l'ancien compte reste utilisable.
                val usable = withContext(io) { runCatching { aead.get() }.isSuccess }
                if (usable) return@withLock false
                withContext(io) { keys.destroy() }
                // L'ancien fichier ne se déchiffre plus avec la nouvelle clé : il est remplacé par un état vide, que
                // l'écriture suivante chiffre avec la nouvelle clé.
                sessions.updateData { SessionHolder() }
                true
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
            return create(
                sessionFile = SessionStorageFiles.sessionFile(appContext.filesDir),
                accountFile = SessionStorageFiles.accountFile(appContext.filesDir),
                aead = source,
                scope = CoroutineScope(dispatcher + SupervisorJob()),
                keys = source,
                io = dispatcher,
            )
        }

        internal fun create(
            sessionFile: File,
            accountFile: File,
            aead: AeadSource,
            scope: CoroutineScope,
            keys: SessionKeys = SessionKeys.None,
            io: CoroutineDispatcher = Dispatchers.IO,
            monotonicMillis: () -> Long = { System.nanoTime() / NANOS_PER_MILLI },
        ): DataStoreSecureStateStore {
            val monitored = KeyAccessMonitor(aead, monotonicMillis)
            return DataStoreSecureStateStore(
                DataStoreFactory.create(
                    serializer = AeadStateSerializer(monitored),
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
                monitored,
                keys,
                io,
            )
        }

        private const val NANOS_PER_MILLI = 1_000_000L
    }
}

/**
 * Suit les accès à la clé de session, seuls révélateurs d'une clé illisible : une lecture de fichier vide réussit
 * sans clé et ne dit rien. Le stockage est « bloqué » après [STUCK_AFTER_FAILURES] échecs de suite étalés sur au
 * moins [STUCK_AFTER_MILLIS] : plusieurs appelants qui échouent ensemble pendant une même panne passagère n'y
 * suffisent pas. Un seul accès réussi remet tout à zéro.
 */
internal class KeyAccessMonitor(
    private val source: AeadSource,
    private val monotonicMillis: () -> Long,
) : AeadSource {
    private val stuck = MutableStateFlow(false)
    val isStuck: StateFlow<Boolean> = stuck.asStateFlow()

    private var failures = 0
    private var firstFailureAt = 0L

    override fun get(): Aead =
        try {
            source.get().also { record(success = true) }
        } catch (e: SecureStorageUnavailableException) {
            record(success = false)
            throw e
        }

    @Synchronized
    private fun record(success: Boolean) {
        if (success) {
            failures = 0
            stuck.value = false
            return
        }
        val now = monotonicMillis()
        if (failures == 0) firstFailureAt = now
        failures++
        if (failures >= STUCK_AFTER_FAILURES && now - firstFailureAt >= STUCK_AFTER_MILLIS) stuck.value = true
    }

    companion object {
        /** Échecs de suite avant de proposer la réinitialisation. */
        const val STUCK_AFTER_FAILURES = 3

        /** Durée minimale de la série d'échecs : un Keystore lent au démarrage ne suffit pas. */
        const val STUCK_AFTER_MILLIS = 30_000L
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
