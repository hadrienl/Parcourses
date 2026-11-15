package fr.parcourses.core.data.sharing

import fr.parcourses.core.network.dto.ListSharing

/**
 * Ce que le partage confie au moteur de synchronisation (#87, lot 87.6) : sous son verrou de passe, aucune passe ni
 * descente ne s'intercale, et un changement de rôle est traité au même endroit que celui vu à la descente.
 */
interface SharingAccess {
    /** `list_sharing` relue par la feuille « Partager » : personnes et rôle ; un abaissement jette les entrées. */
    suspend fun applySharing(sharing: ListSharing)

    /** « Quitter la liste » : retrait de son propre compte au serveur, puis la liste quitte l'appareil. */
    suspend fun leaveList(listId: String)
}
