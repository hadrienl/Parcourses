package fr.parcourses.app

import android.app.Application
import fr.parcourses.core.network.AuthBootstrap
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.SupabaseConfig
import fr.parcourses.core.network.createSupabaseGateway
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Racine de l'app : le gateway est unique par processus (une seule connexion anonyme à la fois).
 * L'injection (Hilt) arrive avec les écrans (A6) ; d'ici là, les modules lisent [gateway].
 */
class ParcoursesApp : Application() {
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** `null` si l'environnement n'est pas configuré : l'app reste alors entièrement locale. */
    val gateway: RemoteGateway? by lazy {
        SupabaseConfig
            .create(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_PUBLISHABLE_KEY)
            ?.let { createSupabaseGateway(this, it) }
    }

    override fun onCreate() {
        super.onCreate()
        // Au premier lancement, en arrière-plan : l'app est utilisable avant la réponse (tout est local).
        gateway?.let { remote -> appScope.launch { AuthBootstrap.signIn(remote) } }
    }
}
