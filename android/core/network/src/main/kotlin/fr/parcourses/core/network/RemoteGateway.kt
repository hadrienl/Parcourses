package fr.parcourses.core.network

import fr.parcourses.core.network.dto.CategoryRow
import fr.parcourses.core.network.dto.CheckUpload
import fr.parcourses.core.network.dto.EmailCodePurpose
import fr.parcourses.core.network.dto.GraphSnapshotResponse
import fr.parcourses.core.network.dto.ListItemFields
import fr.parcourses.core.network.dto.ListItemRow
import fr.parcourses.core.network.dto.ListItemUpsert
import fr.parcourses.core.network.dto.ListRow
import fr.parcourses.core.network.dto.ListUpsert
import fr.parcourses.core.network.dto.NearbyStoreRow
import fr.parcourses.core.network.dto.ProductResolutionRequest
import fr.parcourses.core.network.dto.RemoteProduct
import fr.parcourses.core.network.dto.ResolvedProductRow
import fr.parcourses.core.network.dto.StoreSearchRow
import fr.parcourses.core.network.dto.TombstoneRow
import fr.parcourses.core.network.dto.VerifiedCode
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

    /**
     * Interroge le serveur : [RemoteError.Unauthorized] si la session n'y est plus valable. [refresh] : rafraîchit
     * d'abord la session, et vise le compte de la session même s'il diffère du dernier connu (vérification d'une
     * suppression du compte, #68 : `refresh_token_not_found` ou `user_not_found` prouvent qu'il n'existe plus).
     */
    suspend fun verifySession(refresh: Boolean = false)

    /**
     * Compte de la session, même différent du dernier connu. Jamais de création : [RemoteError.Unauthorized]
     * sans session, [RemoteError.SecureStorageLocked] si le stockage chiffré est inaccessible.
     */
    suspend fun sessionAccountId(): Uuid

    /**
     * Compte de la session enregistrée, lu sur l'appareil **sans rafraîchissement ni réseau** ; `null` sans session.
     * [RemoteError.SecureStorageLocked] si le stockage chiffré est illisible.
     */
    suspend fun storedSessionAccountId(): Uuid?

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
     * Supprime le compte du jeton [accessToken], gardé en mémoire avant une connexion à un autre compte (#87 §2.3,
     * règle 3) : l'ancien compte anonyme, une fois ses données reprises par le nouveau. Sans rafraîchissement ni
     * contrôle de la session courante. Un échec est sans conséquence (purge des inactifs à 365 jours, #68).
     */
    suspend fun deleteAccount(accessToken: String)

    // region Comptes e-mail (#87, lot 87.5)

    /**
     * Demande un code pour lier [email] au compte anonyme de la session (`updateUser({ email })`). Exige une session
     * du dernier compte connu. Un refus lève [AuthRequestError] (`422 email_exists` : adresse prise, vecteur `010`).
     */
    suspend fun linkEmail(email: String)

    /**
     * Demande un code de connexion au compte existant de [email] (`signInWithOtp`, sans création de compte). Un refus
     * lève [AuthRequestError] (`otp_disabled` : aucun compte pour cette adresse).
     */
    suspend fun signInWithEmail(email: String)

    /**
     * Vérifie le code reçu et adopte la session qu'il ouvre : le même compte pour [EmailCodePurpose.Link], celui de
     * l'adresse pour [EmailCodePurpose.SignIn] (la synchronisation reprend alors les données, `AccountRekey`). Le jeton
     * d'un compte anonyme quitté est gardé **avant** la vérification. Code faux ou expiré : [AuthRequestError].
     */
    suspend fun verifyCode(
        email: String,
        code: String,
        purpose: EmailCodePurpose,
    ): VerifiedCode

    /** Écrit le prénom du compte e-mail (`profiles.display_name`), affiché aux membres de ses listes partagées. */
    suspend fun setDisplayName(name: String)

    /** Prénom du compte de la session, `null` s'il n'en a pas. */
    suspend fun displayName(): String?

    /** Adresse e-mail de la session, lue localement ; `null` pour un compte anonyme ou sans session. */
    suspend fun accountEmail(): String?

    /**
     * Déconnexion : révoque la session sur le serveur quand il répond (`/logout`, portée locale), puis vide la session
     * et le dernier compte connu comme [signOutLocally]. Hors ligne, la session est quand même vidée sur l'appareil.
     */
    suspend fun signOut()

    // endregion

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

    /**
     * Insertion complète d'un article jamais accusé par le serveur, idempotente (`on conflict do nothing`). `false` si
     * rien n'a été inséré (l'article existait déjà, réponse d'un envoi précédent perdue, ou il est enterré) :
     * l'appelant enchaîne alors une mise à jour de ses champs.
     */
    suspend fun insertItem(item: ListItemUpsert): Boolean

    /**
     * Met à jour les seuls champs [fields] (#87 §6.4), sans jamais insérer. `false` si aucune ligne n'a été touchée :
     * article supprimé ailleurs, ou accès perdu (la RLS filtre sans erreur) ; `fetchTombstones(ids)` tranche.
     */
    suspend fun updateItem(
        id: Uuid,
        fields: ListItemFields,
    ): Boolean

    /** `false` si aucune ligne n'a été supprimée (même ambiguïté que [updateItem]). */
    suspend fun deleteItem(id: Uuid): Boolean

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

    /** Tous les articles d'une liste, sans curseur : liste nouvellement accessible, ou rechargée (`refreshAccess`). */
    suspend fun fetchItems(listId: Uuid): List<ListItemRow>

    /** Identifiants des articles d'une liste (réconciliation complète des suppressions, vecteur `007`). */
    suspend fun fetchItemIds(listId: Uuid): List<Uuid>

    /** Listes lisibles par le compte (RPC `accessible_list_ids`, vecteur `005`). */
    suspend fun accessibleListIds(): List<Uuid>

    /** Pierres tombales depuis [after] (recouvrement de quelques secondes, comme les autres curseurs). */
    suspend fun fetchTombstones(after: Instant?): List<TombstoneRow>

    /** Pierres tombales de ces articles : lève le doute après une mise à jour sans ligne (vecteur `003`). */
    suspend fun fetchTombstones(ids: List<Uuid>): List<TombstoneRow>

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
