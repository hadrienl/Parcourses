package fr.parcourses.core.network

import android.util.Log
import kotlinx.coroutines.CancellationException

/** Prépare l'accès distant au lancement. Sans configuration, l'app reste entièrement locale. */
object AuthBootstrap {
    private const val TAG = "AuthBootstrap"

    /**
     * Connexion anonyme en tâche de fond. Un échec n'empêche rien : tout est local et la file attend.
     * Renvoie `true` si une session valable existe.
     */
    suspend fun signIn(gateway: RemoteGateway): Boolean =
        try {
            gateway.ensureSession()
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: RemoteError) {
            // Le code seul est journalisé : ni jeton ni donnée de l'utilisateur.
            Log.i(TAG, "Connexion anonyme reportée : ${e.message}")
            false
        }
}
