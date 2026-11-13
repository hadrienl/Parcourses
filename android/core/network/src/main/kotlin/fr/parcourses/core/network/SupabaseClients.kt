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
import io.github.jan.supabase.logging.LogLevel
import io.github.jan.supabase.postgrest.Postgrest
import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.okhttp.OkHttp
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

/**
 * Passerelle de production : session chiffrée (DataStore + Tink + Keystore), OkHttp, pas de Realtime (#10, §4.2).
 * Création sans effet réseau : la connexion anonyme se fait par [AuthBootstrap.signIn].
 */
fun createSupabaseGateway(
    context: Context,
    config: SupabaseConfig,
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
): SupabaseGateway {
    val store = DataStoreSecureStateStore.create(context, dispatcher)
    return SupabaseGateway(createSupabaseClient(config, store, okHttpEngine(), dispatcher), store)
}

/** Moteur HTTP de l'app : OkHttp, avec le seul intercepteur qui distingue une requête jamais partie. */
internal fun okHttpEngine(): HttpClientEngine = OkHttp.create { addInterceptor(NotSentInterceptor) }

/**
 * La requête n'a pas quitté l'appareil (#68, C4) : elle est marquée avant que supabase-kt ne remplace l'erreur par
 * une `HttpRequestException` sans cause. Ne journalise rien.
 */
internal object NotSentInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response =
        try {
            chain.proceed(chain.request())
        } catch (e: IOException) {
            throw markIfNotSent(e)
        }
}

/** [e] marquée si elle prouve que rien n'est parti, sinon telle quelle. */
internal fun markIfNotSent(e: IOException): IOException = if (e.isNotSentCause()) RequestNotSentException(e) else e

/** Requête jamais partie : son message porte [MARKER], seul indice qui survit à supabase-kt. */
class RequestNotSentException(
    cause: IOException,
) : IOException("$MARKER ${cause.javaClass.simpleName}", cause) {
    companion object {
        const val MARKER = "parcourses-not-sent"
    }
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
        // Aucun journal HTTP (corps, en-têtes, jetons), quel que soit le type de build.
        defaultLogLevel = LogLevel.NONE
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
        createSupabaseClient(config, store, okHttpEngine(), dispatcher, lifecycleCallbacks = false),
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
