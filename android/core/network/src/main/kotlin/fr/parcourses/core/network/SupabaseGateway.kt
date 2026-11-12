package fr.parcourses.core.network

import fr.parcourses.core.network.dto.CategoryRow
import fr.parcourses.core.network.dto.CheckInsert
import fr.parcourses.core.network.dto.CheckUpload
import fr.parcourses.core.network.dto.GraphSnapshotResponse
import fr.parcourses.core.network.dto.ListItemPatch
import fr.parcourses.core.network.dto.ListItemRow
import fr.parcourses.core.network.dto.ListItemUpsert
import fr.parcourses.core.network.dto.ListPatch
import fr.parcourses.core.network.dto.ListRow
import fr.parcourses.core.network.dto.ListUpsert
import fr.parcourses.core.network.dto.NearbyStoreRow
import fr.parcourses.core.network.dto.ProductResolutionRequest
import fr.parcourses.core.network.dto.ProductRow
import fr.parcourses.core.network.dto.RemoteProduct
import fr.parcourses.core.network.dto.ResolvedProductRow
import fr.parcourses.core.network.dto.StoreSearchRow
import fr.parcourses.core.network.dto.TableSpec
import fr.parcourses.core.network.dto.VisitAccess
import fr.parcourses.core.network.dto.VisitClose
import fr.parcourses.core.network.dto.VisitInsert
import fr.parcourses.core.network.session.SecureStateStore
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Les `null` sont explicites : colonnes identiques dans un lot, et une mise à jour peut vider une colonne. */
internal val RemoteJson: Json =
    Json {
        ignoreUnknownKeys = true
        explicitNulls = true
        encodeDefaults = true
    }

/**
 * Seul type de l'app qui parle à supabase-kt. Aucune opération ne crée de compte, sauf [ensureSession].
 */
@Suppress("TooManyFunctions")
class SupabaseGateway internal constructor(
    private val client: SupabaseClient,
    private val store: SecureStateStore,
    private val clock: Clock = Clock.System,
) : RemoteGateway,
    SessionMaintenance {
    private val auth: Auth get() = client.auth
    private val rest: Postgrest get() = client.postgrest

    /** Une seule connexion à la fois : deux appels concurrents ne doivent pas créer deux comptes. */
    private val signInLock = Mutex()
    private val categoryLock = Mutex()
    private var categoryMap: CategoryMap? = null

    // region Session

    override suspend fun ensureSession(captchaToken: String?): Uuid =
        mapped {
            val id = currentOrNewUser(captchaToken)
            guardAccount(id)
            id
        }

    override suspend fun currentAccountId(): Uuid = mapped { resolveExistingSession() }

    override suspend fun verifySession() {
        mapped {
            resolveExistingSession()
            auth.retrieveUserForCurrentSession(updateSession = false)
        }
    }

    override suspend fun sessionAccountId(): Uuid = mapped { existingSessionUser() }

    override suspend fun acknowledgeAccount(id: Uuid) {
        mapped { store.update { it.copy(lastAccountId = id.toString()) } }
    }

    override val isSessionStorageStuck: StateFlow<Boolean> get() = store.isStuck

    override suspend fun resetSession(): Boolean =
        mapped {
            // Sous le verrou de connexion : aucun compte ne se crée pendant la réinitialisation.
            signInLock.withLock {
                val reset = store.resetSession()
                // Après le stockage : effacée d'abord, la session du SDK serait réécrite dans l'ancien stockage.
                if (reset) auth.clearSession()
                reset
            }
        }

    override suspend fun serverDate(): Instant? =
        authorized {
            // Lecture minimale : seul l'en-tête compte, et il prouve que PostgREST répond.
            val result = rest.from(CategoryRow.spec.table).select(Columns.list("id")) { limit(1) }
            result.headers["Date"]?.let(::parseHttpDate)
        }

    /** Compte de la session après contrôle du dernier compte connu. */
    private suspend fun resolveExistingSession(): Uuid {
        val id = existingSessionUser()
        guardAccount(id)
        return id
    }

    private suspend fun guardAccount(id: Uuid) {
        val known = store.read().lastAccountId
        if (known == null) {
            store.update { it.copy(lastAccountId = id.toString()) }
        } else if (known != id.toString()) {
            throw RemoteError.AccountChanged()
        }
    }

    private suspend fun existingSessionUser(): Uuid {
        // Charge la session depuis le stockage chiffré si l'auto-chargement n'a pas (encore) abouti, par
        // exemple dans un travail d'arrière-plan.
        if (auth.currentSessionOrNull() == null) auth.loadFromStorage()
        if (auth.currentSessionOrNull() == null) {
            // Stockage inaccessible : `currentSessionOrNull` est nul alors que la session existe.
            store.read()
            throw RemoteError.Unauthorized()
        }
        refreshIfExpiring()
        return userId()
    }

    private suspend fun refreshIfExpiring() {
        val session = auth.currentSessionOrNull() ?: return
        // Hors premier plan, le rafraîchissement automatique de la bibliothèque est arrêté.
        if (session.expiresAt - REFRESH_MARGIN <= clock.now()) auth.refreshCurrentSession()
    }

    private fun userId(): Uuid {
        val id = auth.currentUserOrNull()?.id ?: throw RemoteError.Unauthorized()
        return Uuid.parse(id)
    }

    private suspend fun currentOrNewUser(captchaToken: String?): Uuid {
        existingOrNull()?.let { return it }
        return signInLock.withLock {
            // Un appel concurrent a pu créer le compte pendant l'attente.
            existingOrNull()?.let { return@withLock it }
            // Stockage inaccessible (démarrage direct, clé indisponible) : on échoue ici, avant de créer un compte
            // dont la session ne pourrait pas être enregistrée (compte orphelin).
            store.checkWritable()
            auth.signInAnonymously(captchaToken = captchaToken)
            if (auth.currentSessionOrNull() == null) throw RemoteError.Unauthorized()
            userId()
        }
    }

    /** Session valable, ou `null` si elle a disparu pour de bon (seul cas où un nouveau compte est légitime). */
    private suspend fun existingOrNull(): Uuid? =
        try {
            existingSessionUser()
        } catch (e: RemoteError.Unauthorized) {
            // Le SDK garde la session sur certains échecs : on ne crée un compte que si elle a disparu.
            if (auth.currentSessionOrNull() == null) null else throw e
        } catch (e: io.github.jan.supabase.auth.exception.AuthRestException) {
            if (e.isSessionGone() && auth.currentSessionOrNull() == null) null else throw e
        }

    // endregion

    // region Listes et articles

    override suspend fun saveList(list: ListUpsert) {
        authorized {
            val updated =
                rest
                    .from(ListUpsert.spec.table)
                    .update(RemoteJson.encodeToJsonElement(ListPatch.serializer(), ListPatch(list.name))) {
                        select(Columns.list("id"))
                        filter { eq("id", list.id.toString()) }
                    }.data
            if (isEmptyResult(updated)) insertIgnoringDuplicates(ListUpsert.spec, listOf(list))
        }
    }

    override suspend fun deleteList(id: Uuid) {
        authorized { rest.from(ListUpsert.spec.table).delete { filter { eq("id", id.toString()) } } }
    }

    override suspend fun saveItem(item: ListItemUpsert) {
        authorized {
            val patch = ListItemPatch(item.listId, item.productId, item.label, item.quantity, item.checkedAt)
            val updated =
                rest
                    .from(ListItemUpsert.spec.table)
                    .update(RemoteJson.encodeToJsonElement(ListItemPatch.serializer(), patch)) {
                        select(Columns.list("id"))
                        filter { eq("id", item.id.toString()) }
                    }.data
            if (isEmptyResult(updated)) insertIgnoringDuplicates(ListItemUpsert.spec, listOf(item))
        }
    }

    override suspend fun deleteItem(id: Uuid) {
        authorized { rest.from(ListItemUpsert.spec.table).delete { filter { eq("id", id.toString()) } } }
    }

    // endregion

    // region Visites et coches

    override suspend fun createVisit(visit: VisitInsert) {
        authorized { insertIgnoringDuplicates(VisitInsert.spec, listOf(visit)) }
    }

    override suspend fun insertChecks(checks: List<CheckUpload>) {
        if (checks.isEmpty()) return
        authorized { insertIgnoringDuplicates(CheckInsert.spec, wireChecks(checks)) }
    }

    private suspend fun wireChecks(checks: List<CheckUpload>): List<CheckInsert> =
        checks.map { check ->
            when (val target = check.target) {
                is CheckUpload.Target.Product -> {
                    CheckInsert.forProduct(check.id, check.visitId, target.id, check.checkedAt)
                }

                is CheckUpload.Target.Category -> {
                    CheckInsert.forCategory(check.id, check.visitId, remoteCategoryId(target.slug), check.checkedAt)
                }
            }
        }

    private suspend fun remoteCategoryId(slug: String): Short {
        var map = currentCategoryMap()
        if (map.shouldReload(slug, clock.now())) {
            map = reloadCategoryMap()
            if (map.remoteId(slug) == null) map.markMissing(slug, clock.now())
        }
        return map.remoteId(slug) ?: throw RemoteError.UnknownCategory(slug)
    }

    /** Sans effet si la visite est déjà close : la RLS ne laisse voir que les visites ouvertes. */
    override suspend fun closeVisit(
        id: Uuid,
        endedAt: Instant,
    ) {
        authorized {
            rest
                .from(VisitInsert.spec.table)
                .update(RemoteJson.encodeToJsonElement(VisitClose.serializer(), VisitClose(endedAt))) {
                    filter {
                        eq("id", id.toString())
                        exact("ended_at", null)
                    }
                }
        }
    }

    override suspend fun visitAccess(id: Uuid): VisitAccess =
        authorized {
            val data =
                rest
                    .from(VisitInsert.spec.table)
                    .select(Columns.list("ended_at")) { filter { eq("id", id.toString()) } }
                    .data
            val row =
                (RemoteJson.parseToJsonElement(data) as JsonArray).firstOrNull() as? JsonObject
                    ?: return@authorized VisitAccess.NotVisible
            if (row["ended_at"] is kotlinx.serialization.json.JsonNull) VisitAccess.Open else VisitAccess.Closed
        }

    // endregion

    // region Lecture

    override suspend fun fetchLists(updatedAfter: Instant?): List<ListRow> = fetchUpdated(ListRow.spec, updatedAfter)

    override suspend fun fetchItems(updatedAfter: Instant?): List<ListItemRow> =
        fetchUpdated(ListItemRow.spec, updatedAfter)

    override suspend fun fetchCategories(): List<CategoryRow> = authorized { loadCategories() }

    override suspend fun fetchProducts(): List<RemoteProduct> =
        authorized {
            val rows =
                fetchAllPages(ProductRow.serializer()) { from, to ->
                    rest
                        .from(ProductRow.spec.table)
                        .select(Columns.raw(ProductRow.spec.selection)) {
                            order("id", Order.ASCENDING)
                            range(from, to)
                        }.data
                }
            var map = currentCategoryMap()
            if (rows.any { row -> row.categoryId?.let { map.slug(it) } == null && row.categoryId != null }) {
                map = reloadCategoryMap()
            }
            rows.map { row ->
                val slug =
                    row.categoryId?.let { map.slug(it) ?: throw RemoteError.UnknownCategory(it.toString()) }
                RemoteProduct(row.id, row.name, row.normalizedName, slug, row.offCode, row.createdAt)
            }
        }

    override suspend fun resolveProducts(items: List<ProductResolutionRequest>): List<ResolvedProductRow> {
        if (items.isEmpty()) return emptyList()
        val parameters =
            buildJsonObject {
                put(
                    "p_items",
                    RemoteJson.encodeToJsonElement(ListSerializer(ProductResolutionRequest.serializer()), items),
                )
            }
        return authorized { decodeRpc("resolve_products", parameters, ListSerializer(ResolvedProductRow.serializer())) }
    }

    override suspend fun nearbyStores(
        lat: Double,
        lng: Double,
        radiusM: Int,
        maxResults: Int,
    ): List<NearbyStoreRow> {
        val parameters =
            buildJsonObject {
                put("lat", lat)
                put("lng", lng)
                put("radius_m", radiusM)
                put("max_results", maxResults)
            }
        return authorized { decodeRpc("nearby_stores", parameters, ListSerializer(NearbyStoreRow.serializer())) }
    }

    override suspend fun searchStores(
        query: String,
        limit: Int,
    ): List<StoreSearchRow> {
        val parameters =
            buildJsonObject {
                put("q", query)
                put("max_results", limit)
            }
        return authorized { decodeRpc("search_stores", parameters, ListSerializer(StoreSearchRow.serializer())) }
    }

    override suspend fun storeOrganicAisle(id: Uuid): Boolean? =
        authorized {
            val data =
                rest
                    .from("stores")
                    .select(Columns.list("organic_aisle")) { filter { eq("id", id.toString()) } }
                    .data
            val row = (RemoteJson.parseToJsonElement(data) as JsonArray).firstOrNull() as? JsonObject
            (row?.get("organic_aisle") as? kotlinx.serialization.json.JsonPrimitive)?.content?.toBooleanStrictOrNull()
        }

    override suspend fun graphSnapshot(
        storeId: Uuid,
        knownVersion: Long?,
    ): GraphSnapshotResponse {
        val parameters =
            buildJsonObject {
                put("p_store_id", storeId.toString())
                put("p_known_version", knownVersion)
            }
        return authorized { GraphSnapshotResponse.parse(rest.rpc("store_graph_snapshot", parameters).data) }
    }

    // endregion

    // region Outils

    private suspend fun loadCategories(): List<CategoryRow> {
        val data =
            rest
                .from(CategoryRow.spec.table)
                .select(Columns.raw(CategoryRow.spec.selection)) { order("default_rank", Order.ASCENDING) }
                .data
        val rows = RemoteJson.decodeFromString(ListSerializer(CategoryRow.serializer()), data)
        categoryLock.withLock { categoryMap = CategoryMap(rows, categoryMap?.missingSlugs.orEmpty()) }
        return rows
    }

    private suspend fun currentCategoryMap(): CategoryMap = categoryLock.withLock { categoryMap } ?: reloadCategoryMap()

    private suspend fun reloadCategoryMap(): CategoryMap {
        loadCategories()
        return categoryLock.withLock { categoryMap } ?: error("categories")
    }

    private suspend fun <T : Any> fetchUpdated(
        spec: TableSpec<T>,
        updatedAfter: Instant?,
    ): List<T> =
        authorized {
            fetchAllPages(spec.serializer) { from, to ->
                rest
                    .from(spec.table)
                    .select(Columns.raw(spec.selection)) {
                        if (updatedAfter != null) {
                            filter { gte("updated_at", (updatedAfter - CURSOR_OVERLAP).toString()) }
                        }
                        // `id` départage les lignes de même date : sans lui, une page pourrait en sauter.
                        order("updated_at", Order.ASCENDING)
                        order("id", Order.ASCENDING)
                        range(from, to)
                    }.data
            }
        }

    private suspend fun <T> fetchAllPages(
        serializer: KSerializer<T>,
        page: suspend (from: Long, to: Long) -> String,
    ): List<T> {
        val rows = mutableListOf<T>()
        while (true) {
            val next =
                RemoteJson.decodeFromString(
                    ListSerializer(serializer),
                    page(rows.size.toLong(), rows.size + PAGE_SIZE - 1L),
                )
            if (next.isEmpty()) return rows
            rows += next
        }
    }

    private suspend fun <T> decodeRpc(
        function: String,
        parameters: JsonObject,
        serializer: KSerializer<T>,
    ): T = RemoteJson.decodeFromString(serializer, rest.rpc(function, parameters).data)

    /** `on conflict (id) do nothing` : un renvoi après une perte de réseau ne crée pas de doublon. */
    private suspend fun <T : Any> insertIgnoringDuplicates(
        spec: TableSpec<T>,
        values: List<T>,
    ) {
        val body = RemoteJson.encodeToJsonElement(ListSerializer(spec.serializer), values) as JsonArray
        rest.from(spec.table).upsert(body) {
            onConflict = "id"
            ignoreDuplicates = true
        }
    }

    private fun isEmptyResult(data: String): Boolean =
        (RemoteJson.parseToJsonElement(data.ifBlank { "[]" }) as? JsonArray)?.isEmpty() ?: true

    /** Toute requête passe par une session valide du même compte, puis ses erreurs sont classées. */
    private suspend fun <T> authorized(operation: suspend () -> T): T =
        mapped {
            // Jamais de compte créé ici : sans session, l'appelant reçoit `Unauthorized` et attend.
            resolveExistingSession()
            operation()
        }

    // endregion

    private companion object {
        /** `max_rows` côté serveur. La pagination avance du nombre de lignes reçues. */
        const val PAGE_SIZE = 1000

        /** Recouvrement du curseur : deux transactions proches peuvent valider dans le désordre. */
        val CURSOR_OVERLAP = 5.seconds

        /** Rafraîchit un peu avant l'expiration pour qu'une requête en cours ne parte pas avec un jeton périmé. */
        val REFRESH_MARGIN = 30.seconds

        fun parseHttpDate(value: String): Instant? =
            try {
                Instant.fromEpochMilliseconds(
                    DateTimeFormatter.RFC_1123_DATE_TIME.parse(value, java.time.Instant::from).toEpochMilli(),
                )
            } catch (_: DateTimeParseException) {
                null
            }
    }
}
