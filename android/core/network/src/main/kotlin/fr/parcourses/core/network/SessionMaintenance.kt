package fr.parcourses.core.network

import kotlinx.coroutines.flow.StateFlow

/**
 * Entretien de la session de l'appareil, à la demande de la personne (écran À propos), à côté de la
 * synchronisation. La suppression du compte (#68) passe par `RemoteGateway.deleteAccount`, portée par
 * `AccountDeletion` (`:core:data`).
 */
interface SessionMaintenance {
    /** Le stockage chiffré de la session reste illisible : la synchronisation est arrêtée sans issue automatique. */
    val isSessionStorageStuck: StateFlow<Boolean>

    /**
     * Oublie la session de cet appareil quand sa clé reste illisible : clés détruites, session effacée, SDK
     * déconnecté localement, sans appel au serveur. Le dernier compte connu est gardé : au prochain
     * `ensureSession`, le nouveau compte anonyme lève [RemoteError.AccountChanged] et la synchronisation réidentifie
     * les données locales.
     * L'ancien compte reste sur le serveur, sans session pour l'atteindre.
     * @return `false` si la clé s'ouvre de nouveau entre-temps : rien n'est oublié.
     * @throws RemoteError.SecureStorageLocked si le Keystore refuse l'effacement.
     */
    suspend fun resetSession(): Boolean
}
