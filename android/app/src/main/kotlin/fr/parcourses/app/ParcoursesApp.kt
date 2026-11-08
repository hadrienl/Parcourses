package fr.parcourses.app

import android.app.Application
import androidx.work.Configuration
import fr.parcourses.core.data.sync.SyncWorkerFactory
import fr.parcourses.feature.shopping.live.LiveUpdateHost
import fr.parcourses.feature.shopping.live.ShoppingLiveUpdates
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** Racine de l'app : le [container] est unique par processus (une seule connexion anonyme à la fois). */
class ParcoursesApp :
    Application(),
    Configuration.Provider,
    LiveUpdateHost {
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val container: AppContainer by lazy { AppContainer(this) }

    // Le receiver de la Live Update retrouve ici l'instance unique du contrôleur.
    override val liveUpdates: ShoppingLiveUpdates get() = container.liveUpdates

    // WorkManager lit cette configuration à son démarrage, avant `onCreate` : le conteneur reste paresseux.
    override val workManagerConfiguration: Configuration
        get() =
            Configuration
                .Builder()
                .setWorkerFactory(SyncWorkerFactory(engine = { container.engine }, scheduler = container.scheduler))
                .build()

    override fun onCreate() {
        super.onCreate()
        container.start(appScope)
    }
}
