package fr.parcourses.core.data

import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.dto.CategoryRow
import fr.parcourses.core.network.dto.CheckUpload
import fr.parcourses.core.network.dto.EmailCodePurpose
import fr.parcourses.core.network.dto.EmailCodeStatus
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
import fr.parcourses.core.network.dto.VisitAccess
import fr.parcourses.core.network.dto.VisitInsert
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Doublure du serveur : enregistre les appels et lève les erreurs programmées, méthode par méthode. */
@Suppress("TooManyFunctions")
class FakeRemoteGateway(
    /** Listes de l'appareil : par défaut, le serveur n'en a supprimé aucune (voir [accessible]). */
    private val localLists: suspend () -> List<String> = { emptyList() },
) : RemoteGateway {
    var account: Uuid = Uuid.random()
    var serverDate: Instant? = null
    var visitAccess = VisitAccess.Open
    var remoteLists: List<ListRow> = emptyList()
    var remoteItems: List<ListItemRow> = emptyList()
    var remoteCategories: List<CategoryRow> = emptyList()
    var remoteProducts: List<RemoteProduct> = emptyList()
    var resolver: (
        List<ProductResolutionRequest>,
    ) -> List<ResolvedProductRow> = { list -> list.map { ResolvedProductRow() } }

    /** Pierres tombales du serveur (#87). */
    var tombstones: List<TombstoneRow> = emptyList()

    /**
     * Listes lisibles (`accessible_list_ids`). Par défaut : celles de l'appareil, de [remoteLists], et celles envoyées
     * par `saveList`, comme un serveur sans partage qui n'a rien supprimé.
     */
    var accessible: (() -> List<Uuid>)? = null
    private val savedLists = mutableSetOf<Uuid>()
    private val deletedItems = mutableSetOf<Uuid>()

    /** Réponse de `updateItem` / `deleteItem` : `false` = aucune ligne touchée. */
    var rowTouched: (Uuid) -> Boolean = { true }

    /** Réponses de GoTrue aux demandes de code. */
    var linkStatus: EmailCodeStatus = EmailCodeStatus.Sent
    var signInStatus: EmailCodeStatus = EmailCodeStatus.Sent

    /** Compte ouvert par `verifyCode` : `null` = le même ([EmailCodePurpose.Link]). */
    var codeAccount: Uuid? = null
    var email: String? = null
    var displayName: String? = null
    val deletedTokens = mutableListOf<String>()

    /** Appels, dans l'ordre : `saveList:<id>`, `insertItem:<id>`, `updateItem:<id>`, `resolveProducts`… */
    val calls = mutableListOf<String>()
    val savedItems = mutableListOf<ListItemUpsert>()

    /** Champs envoyés par `updateItem`, dans l'ordre. */
    val patches = mutableListOf<ListItemFields>()
    val savedChecks = mutableListOf<List<CheckUpload>>()
    val acknowledged = mutableListOf<Uuid>()
    private val failures = mutableMapOf<String, ArrayDeque<Throwable>>()

    /** Appelé avant chaque méthode, après l'enregistrement de l'appel (pour interrompre au bon endroit). */
    var beforeCall: suspend (String) -> Unit = {}

    fun failNext(
        method: String,
        error: Throwable,
        times: Int = 1,
    ) {
        repeat(times) { failures.getOrPut(method) { ArrayDeque() }.addLast(error) }
    }

    fun callsOf(method: String) = calls.filter { it.substringBefore(':') == method }

    private suspend fun enter(
        method: String,
        detail: String? = null,
    ) {
        calls += if (detail == null) method else "$method:$detail"
        beforeCall(method)
        // Une panne vise une méthode (`saveItem`) ou un appel précis (`saveItem:<id>`).
        val queue = failures["$method:$detail"]?.takeIf { it.isNotEmpty() } ?: failures[method]
        queue?.removeFirstOrNull()?.let { throw it }
    }

    /** Session de l'appareil : [signOutLocally] l'oublie, et le [ensureSession] suivant crée un nouveau compte. */
    var hasSession = true

    /** Comptes supprimés par [deleteAccount] (#68). */
    val deletedAccounts = mutableListOf<Uuid>()

    /** Réponse perdue : le serveur supprime le compte, puis l'app reçoit cette erreur. */
    var lostDeleteResponse: Throwable? = null

    override suspend fun ensureSession(captchaToken: String?): Uuid {
        enter("ensureSession")
        if (!hasSession) {
            account = Uuid.random()
            hasSession = true
        }
        return account
    }

    override suspend fun deleteAccount() {
        enter("deleteAccount")
        requireSession()
        // Rejouée après une réponse perdue : le rafraîchissement est refusé, la session ne vaut plus rien.
        if (account in deletedAccounts) throw RemoteError.Unauthorized(authCode = "refresh_token_not_found")
        deletedAccounts += account
        lostDeleteResponse?.let {
            lostDeleteResponse = null
            throw it
        }
    }

    override suspend fun signOutLocally() {
        enter("signOutLocally")
        hasSession = false
    }

    override suspend fun currentAccountId(): Uuid = account.also { enter("currentAccountId") }.also { requireSession() }

    /** Après [deleteAccount], le serveur répond « introuvable », avec le code de GoTrue (contrat 68.1). */
    override suspend fun verifySession(refresh: Boolean) {
        enter("verifySession")
        requireSession()
        if (account in deletedAccounts) {
            throw RemoteError.Unauthorized(authCode = if (refresh) "refresh_token_not_found" else "user_not_found")
        }
    }

    override suspend fun sessionAccountId(): Uuid = account.also { enter("sessionAccountId") }.also { requireSession() }

    private fun requireSession() {
        if (!hasSession) throw RemoteError.Unauthorized(noLocalSession = true)
    }

    override suspend fun acknowledgeAccount(id: Uuid) {
        enter("acknowledgeAccount")
        acknowledged += id
    }

    override suspend fun serverDate(): Instant? = serverDate.also { enter("serverDate") }

    override suspend fun saveList(list: ListUpsert) {
        enter("saveList", list.id.toString())
        savedLists += list.id
    }

    override suspend fun deleteList(id: Uuid) = enter("deleteList", id.toString())

    override suspend fun insertItem(item: ListItemUpsert) {
        enter("insertItem", item.id.toString())
        savedItems += item
    }

    override suspend fun updateItem(
        id: Uuid,
        fields: ListItemFields,
    ): Boolean {
        enter("updateItem", id.toString())
        patches += fields
        return rowTouched(id).also { if (it) savedItems += fields.values }
    }

    override suspend fun deleteItem(id: Uuid): Boolean {
        enter("deleteItem", id.toString())
        return rowTouched(id).also { if (it) deletedItems += id }
    }

    override suspend fun createVisit(visit: VisitInsert) = enter("createVisit", visit.id.toString())

    override suspend fun insertChecks(checks: List<CheckUpload>) {
        enter("insertChecks", checks.size.toString())
        savedChecks += checks
    }

    override suspend fun closeVisit(
        id: Uuid,
        endedAt: Instant,
    ) = enter("closeVisit", id.toString())

    override suspend fun visitAccess(id: Uuid): VisitAccess = visitAccess.also { enter("visitAccess") }

    override suspend fun fetchLists(updatedAfter: Instant?): List<ListRow> = remoteLists.also { enter("fetchLists") }

    override suspend fun fetchItems(updatedAfter: Instant?): List<ListItemRow> =
        remoteItems.also { enter("fetchItems") }

    override suspend fun fetchItems(listId: Uuid): List<ListItemRow> =
        remoteItems.filter { it.listId == listId }.also { enter("fetchItemsOfList", listId.toString()) }

    /** Articles connus du serveur : ceux de [remoteItems] et ceux reçus, moins ceux supprimés. */
    override suspend fun fetchItemIds(listId: Uuid): List<Uuid> {
        enter("fetchItemIds", listId.toString())
        val ids =
            remoteItems.filter { it.listId == listId }.map { it.id } +
                savedItems.filter { it.listId == listId }.map { it.id }
        return ids.distinct() - deletedItems
    }

    override suspend fun accessibleListIds(): List<Uuid> {
        enter("accessibleListIds")
        return accessible?.invoke()
            ?: (localLists().map(Uuid::parse) + remoteLists.map { it.id } + savedLists).distinct()
    }

    override suspend fun fetchTombstones(after: Instant?): List<TombstoneRow> {
        enter("fetchTombstones")
        return tombstones.filter { after == null || it.deletedAt >= after }
    }

    override suspend fun fetchTombstones(ids: List<Uuid>): List<TombstoneRow> {
        enter("fetchTombstonesOf", ids.joinToString(","))
        return tombstones.filter { it.id in ids }
    }

    override suspend fun deleteAccount(accessToken: String) {
        enter("deleteAccountWithToken")
        deletedTokens += accessToken
    }

    override suspend fun accessToken(): String? = if (hasSession) "token-$account" else null

    override suspend fun linkEmail(email: String): EmailCodeStatus {
        enter("linkEmail", email)
        requireSession()
        return linkStatus
    }

    override suspend fun signInWithEmail(email: String): EmailCodeStatus {
        enter("signInWithEmail", email)
        return signInStatus
    }

    override suspend fun verifyCode(
        email: String,
        code: String,
        purpose: EmailCodePurpose,
    ): Uuid {
        enter("verifyCode", purpose.wireName)
        codeAccount?.let { account = it }
        hasSession = true
        this.email = email
        return account
    }

    override suspend fun setDisplayName(name: String) {
        enter("setDisplayName", name)
        displayName = name
    }

    override suspend fun displayName(): String? = displayName.also { enter("displayName") }

    override suspend fun accountEmail(): String? = email

    override suspend fun signOut() {
        enter("signOut")
        hasSession = false
    }

    override suspend fun fetchCategories(): List<CategoryRow> = remoteCategories.also { enter("fetchCategories") }

    override suspend fun fetchProducts(): List<RemoteProduct> = remoteProducts.also { enter("fetchProducts") }

    override suspend fun resolveProducts(items: List<ProductResolutionRequest>): List<ResolvedProductRow> {
        enter("resolveProducts")
        return resolver(items)
    }

    override suspend fun nearbyStores(
        lat: Double,
        lng: Double,
        radiusM: Int,
        maxResults: Int,
    ): List<NearbyStoreRow> = emptyList()

    override suspend fun searchStores(
        query: String,
        limit: Int,
    ): List<StoreSearchRow> = emptyList()

    override suspend fun storeOrganicAisle(id: Uuid): Boolean? = null

    override suspend fun graphSnapshot(
        storeId: Uuid,
        knownVersion: Long?,
    ): GraphSnapshotResponse = GraphSnapshotResponse.Unchanged
}
