package fr.parcourses.core.network

import fr.parcourses.core.network.dto.CategoryRow
import fr.parcourses.core.network.dto.CheckUpload
import fr.parcourses.core.network.dto.GraphSnapshotResponse
import fr.parcourses.core.network.dto.ListItemRow
import fr.parcourses.core.network.dto.ListItemUpsert
import fr.parcourses.core.network.dto.ListRow
import fr.parcourses.core.network.dto.ListUpsert
import fr.parcourses.core.network.dto.NearbyStoreRow
import fr.parcourses.core.network.dto.ProductResolutionRequest
import fr.parcourses.core.network.dto.RemoteProduct
import fr.parcourses.core.network.dto.ResolvedProductRow
import fr.parcourses.core.network.dto.StoreSearchRow
import fr.parcourses.core.network.dto.VisitAccess
import fr.parcourses.core.network.dto.VisitInsert
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * Accès distant de l'app. [SupabaseGateway] en est l'implémentation ; les tests fournissent une doublure.
 * Toutes les écritures sont idempotentes : la file peut les rejouer. Elles lèvent [RemoteError].
 * Même contrat que `RemoteGateway` côté iOS.
 */
@Suppress("TooManyFunctions")
interface RemoteGateway {
    /** Renvoie l'utilisateur courant, et crée un compte anonyme s'il n'y a pas de session. */
    suspend fun ensureSession(captchaToken: String? = null): Uuid

    /** Compte de la session existante, sans jamais en créer : [RemoteError.Unauthorized] s'il n'y en a pas. */
    suspend fun currentAccountId(): Uuid

    /** Interroge le serveur : [RemoteError.Unauthorized] si la session n'y est plus valable. */
    suspend fun verifySession()

    /**
     * Compte de la session, même différent du dernier connu. Jamais de création : [RemoteError.Unauthorized]
     * sans session, [RemoteError.SecureStorageLocked] si le stockage chiffré est inaccessible.
     */
    suspend fun sessionAccountId(): Uuid

    /** Les données locales ont été réidentifiées pour [id] : il devient le dernier compte connu. */
    suspend fun acknowledgeAccount(id: Uuid)

    /**
     * Supprime, sur le serveur, le compte de la session et tout ce qui y est rattaché (RPC `delete_my_account`, #68).
     * Rafraîchit d'abord la session : le jeton d'accès reste alors valable une heure, le temps de rejouer l'appel
     * (idempotent) si la réponse s'est perdue. Vise le compte de la session, même s'il diffère du dernier connu.
     * Jamais de création : [RemoteError.Unauthorized] sans session.
     */
    suspend fun deleteAccount()

    /**
     * Déconnexion locale, **sans appel au serveur** : la session du SDK, la session enregistrée et le dernier compte
     * connu sont vidés. Le prochain [ensureSession] adopte alors un nouveau compte sans le signaler comme un
     * changement (aucune réidentification). Le jeu de clés et la clé du Keystore restent.
     * @throws RemoteError.SecureStorageLocked si le stockage chiffré refuse l'écriture.
     */
    suspend fun signOutLocally()

    /** Heure du serveur (en-tête HTTP `Date`), `null` si la réponse n'en porte pas de lisible. */
    suspend fun serverDate(): Instant?

    suspend fun saveList(list: ListUpsert)

    suspend fun deleteList(id: Uuid)

    suspend fun saveItem(item: ListItemUpsert)

    suspend fun deleteItem(id: Uuid)

    suspend fun createVisit(visit: VisitInsert)

    suspend fun insertChecks(checks: List<CheckUpload>)

    suspend fun closeVisit(
        id: Uuid,
        endedAt: Instant,
    )

    /** Ce que la RLS laisse voir d'une visite : distingue une coche tardive d'une visite d'un autre compte. */
    suspend fun visitAccess(id: Uuid): VisitAccess

    /** `updatedAfter` a un recouvrement de quelques secondes : l'appelant doit fusionner de façon idempotente. */
    suspend fun fetchLists(updatedAfter: Instant?): List<ListRow>

    suspend fun fetchItems(updatedAfter: Instant?): List<ListItemRow>

    suspend fun fetchCategories(): List<CategoryRow>

    suspend fun fetchProducts(): List<RemoteProduct>

    /**
     * Produits partagés des libellés saisis librement (RPC `resolve_products`), créés au besoin par le serveur.
     * Une ligne par entrée, dans l'ordre.
     */
    suspend fun resolveProducts(items: List<ProductResolutionRequest>): List<ResolvedProductRow>

    /** La position n'est ni conservée ni journalisée ici. */
    suspend fun nearbyStores(
        lat: Double,
        lng: Double,
        radiusM: Int,
        maxResults: Int,
    ): List<NearbyStoreRow>

    /** Repli sans position (refus de localisation) : RPC `search_stores`, par nom ou adresse. */
    suspend fun searchStores(
        query: String,
        limit: Int,
    ): List<StoreSearchRow>

    /** Rayon bio d'un magasin connu par son identifiant. `null` si le serveur ne le connaît pas. */
    suspend fun storeOrganicAisle(id: Uuid): Boolean?

    /** Instantané du graphe d'un magasin, s'il diffère de [knownVersion]. Exige une session, jamais créée ici. */
    suspend fun graphSnapshot(
        storeId: Uuid,
        knownVersion: Long?,
    ): GraphSnapshotResponse
}
