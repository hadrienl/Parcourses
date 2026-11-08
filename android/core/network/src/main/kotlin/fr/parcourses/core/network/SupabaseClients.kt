package fr.parcourses.core.network

import android.content.Context
import fr.parcourses.core.network.session.DataStoreSecureStateStore
import fr.parcourses.core.network.session.EncryptedSessionManager
import fr.parcourses.core.network.session.SecureState
import fr.parcourses.core.network.session.SecureStateStore
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.MemoryCodeVerifierCache
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.okhttp.OkHttp
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Passerelle de production : session chiffrée (DataStore + Tink + Keystore), OkHttp, pas de Realtime (#10, §4.2).
 * Création sans effet réseau : la connexion anonyme se fait par [AuthBootstrap.signIn].
 */
fun createSupabaseGateway(
    context: Context,
    config: SupabaseConfig,
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
): RemoteGateway {
    val store = DataStoreSecureStateStore.create(context, dispatcher)
    return SupabaseGateway(createSupabaseClient(config, store, OkHttp.create(), dispatcher), store)
}

/** Client commun à la production et aux tests : seul le moteur HTTP, le stockage et le cycle de vie changent. */
internal fun createSupabaseClient(
    config: SupabaseConfig,
    store: SecureStateStore,
    engine: HttpClientEngine,
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
    lifecycleCallbacks: Boolean = true,
): SupabaseClient =
    createSupabaseClient(supabaseUrl = config.url, supabaseKey = config.publishableKey) {
        httpEngine = engine
        coroutineDispatcher = dispatcher
        install(Auth) {
            sessionManager = EncryptedSessionManager(store)
            // Pas de flux PKCE ici (connexion anonyme seulement) : rien à persister en clair dans les préférences.
            codeVerifierCache = MemoryCodeVerifierCache()
            enableLifecycleCallbacks = lifecycleCallbacks
        }
        install(Postgrest)
    }

/**
 * Passerelle sans persistance (session en mémoire, aucun Keystore) pour les tests d'intégration contre le
 * Supabase local. Ne sert jamais dans l'app : la session ne survit pas au processus.
 */
fun createInMemorySupabaseGateway(
    config: SupabaseConfig,
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
): RemoteGateway {
    val store = InMemorySecureStateStore()
    return SupabaseGateway(
        createSupabaseClient(config, store, OkHttp.create(), dispatcher, lifecycleCallbacks = false),
        store,
    )
}

private class InMemorySecureStateStore : SecureStateStore {
    private val lock = Mutex()
    private var state = SecureState()

    override suspend fun read(): SecureState = lock.withLock { state }

    override suspend fun update(transform: (SecureState) -> SecureState) {
        lock.withLock { state = transform(state) }
    }
}
