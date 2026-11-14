package fr.parcourses.core.data

import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
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

/** Doublure du serveur : enregistre les appels et lève les erreurs programmées, méthode par méthode. */
@Suppress("TooManyFunctions")
class FakeRemoteGateway : RemoteGateway {
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

    /** Appels, dans l'ordre : `saveList:<id>`, `saveItem:<id>`, `resolveProducts`… */
    val calls = mutableListOf<String>()
    val savedItems = mutableListOf<ListItemUpsert>()
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

    override suspend fun saveList(list: ListUpsert) = enter("saveList", list.id.toString())

    override suspend fun deleteList(id: Uuid) = enter("deleteList", id.toString())

    override suspend fun saveItem(item: ListItemUpsert) {
        enter("saveItem", item.id.toString())
        savedItems += item
    }

    override suspend fun deleteItem(id: Uuid) = enter("deleteItem", id.toString())

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
