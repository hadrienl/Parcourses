package fr.parcourses.core.data.repository

import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.ShoppingListEntity
import fr.parcourses.core.model.ListRole
import kotlinx.coroutines.flow.Flow
import kotlin.time.Instant

/** Erreurs d'écriture des repositories. */
sealed class RepositoryException(
    message: String,
) : Exception(message) {
    class NotFound(
        val id: String,
    ) : RepositoryException("Cet élément n'existe plus.")

    /** Une liste supprimée, en attente d'envoi, n'accepte plus aucune écriture. */
    class ListDeleted(
        val id: String,
    ) : RepositoryException("Cette liste a été supprimée.")

    /** Un article déjà coché ne reçoit pas de seconde coche (double appui, double événement). */
    class AlreadyChecked(
        val id: String,
    ) : RepositoryException("Cet article est déjà coché.")

    /**
     * Lecteur d'une liste partagée (#87, Q5) : ni saisie, ni coche, ni suppression d'article, ni coche de visite. La
     * RLS refuserait l'écriture ; elle est arrêtée ici avant d'entrer dans la file.
     */
    class ReadOnly(
        val id: String,
    ) : RepositoryException("Cette liste est en lecture seule.")

    /** Une coche ne s'ajoute pas à une visite déjà close. */
    class VisitClosed(
        val id: String,
    ) : RepositoryException("Cette visite est déjà terminée.")
}

/**
 * Une liste avec ses compteurs, telle qu'affichée sur l'écran Listes. [role] : mon rôle ; [sharedWith] : prénoms des
 * autres personnes de la liste (propriétaire d'abord), vide si elle n'est pas partagée (#87, lot 87.6).
 */
data class ListSummary(
    val id: String,
    val name: String,
    val remaining: Int,
    val total: Int,
    val role: ListRole = ListRole.Owner,
    val sharedWith: List<String?> = emptyList(),
) {
    val isShared: Boolean get() = sharedWith.isNotEmpty()
}

/**
 * Listes et articles. Les lectures sont des `Flow` Room (source de vérité de l'UI) ; les écritures passent par la
 * base **et** la file d'envoi dans une seule transaction. Mêmes noms que `ListRepository` d'iOS.
 */
@Suppress("TooManyFunctions")
interface ListRepository {
    /** Listes non supprimées avec leurs compteurs, la plus récemment modifiée d'abord. */
    fun observeSummaries(): Flow<List<ListSummary>>

    /** La liste, `null` si elle est inconnue ou supprimée. */
    fun observeList(id: String): Flow<ShoppingListEntity?>

    /** Articles d'une liste, triés par `position`. Vide si la liste est supprimée. */
    fun observeItems(listId: String): Flow<List<ListItemEntity>>

    /** Articles de toutes les listes non supprimées, source de l'autocomplétion. */
    fun observeItemHistory(): Flow<List<ListItemEntity>>

    suspend fun lists(): List<ShoppingListEntity>

    suspend fun list(id: String): ShoppingListEntity?

    suspend fun items(listId: String): List<ListItemEntity>

    /** L'article, `null` s'il est inconnu ou si sa liste est supprimée. */
    suspend fun item(id: String): ListItemEntity?

    suspend fun createList(
        name: String,
        at: Instant,
    ): ShoppingListEntity

    suspend fun renameList(
        id: String,
        name: String,
        at: Instant,
    )

    /** Suppression douce : la liste disparaît des lectures et reste en base jusqu'à l'envoi. */
    suspend fun deleteList(
        id: String,
        at: Instant,
    )

    @Suppress("LongParameterList")
    suspend fun addItem(
        listId: String,
        label: String,
        normalizedName: String,
        quantity: String?,
        productId: String?,
        categoryId: String,
        at: Instant,
    ): ListItemEntity

    suspend fun setChecked(
        itemId: String,
        checkedAt: Instant?,
        at: Instant,
    )

    /**
     * Libellé et quantité d'un article (#110, panneau de l'article et saisie sur un article existant). Seuls les champs
     * qui changent sont écrits et envoyés (triés) : `label`, `quantity`, et `product_id` quand le libellé change de
     * forme normalisée. Un nouveau libellé prend [normalizedName] et [categoryId] (reclassés par l'appelant) ; si sa forme
     * normalisée change, le produit est oublié (`productId` nul, envoyé même s'il l'était déjà ici : le serveur peut en
     * avoir un pas encore descendu) ; la résolution de produit repassera.
     * [normalizedName] et [categoryId] sont ignorés si le libellé ne change pas. Rien ne change : aucune écriture.
     * Refusé en lecture seule.
     */
    @Suppress("LongParameterList")
    suspend fun updateItem(
        itemId: String,
        label: String,
        normalizedName: String,
        categoryId: String,
        quantity: String?,
        at: Instant,
    )

    /** Champ purement local : ni envoi, ni `updatedAt`, qui suit l'état partagé. */
    suspend fun setNotFound(
        itemId: String,
        notFoundAt: Instant?,
    )

    suspend fun deleteItem(
        id: String,
        at: Instant,
    )

    suspend fun itemHistory(): List<ListItemEntity>
}
