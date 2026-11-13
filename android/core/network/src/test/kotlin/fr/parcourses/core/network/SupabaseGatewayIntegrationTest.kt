@file:Suppress("ktlint:standard:max-line-length")

package fr.parcourses.core.network

import fr.parcourses.core.network.dto.CheckUpload
import fr.parcourses.core.network.dto.GraphSnapshotResponse
import fr.parcourses.core.network.dto.ListItemUpsert
import fr.parcourses.core.network.dto.ListUpsert
import fr.parcourses.core.network.dto.ProductResolutionRequest
import fr.parcourses.core.network.dto.VisitAccess
import fr.parcourses.core.network.dto.VisitInsert
import io.ktor.client.engine.okhttp.OkHttp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import kotlin.time.Clock
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.uuid.Uuid

/**
 * Contre le Supabase local uniquement : voir `scripts/integration-test.sh`. Ignorés sinon (CI comprise).
 * Garde-fou : jamais d'écriture de test ailleurs que sur 127.0.0.1.
 */
class SupabaseGatewayIntegrationTest {
    private val config: SupabaseConfig? =
        SupabaseConfig
            .create(System.getenv("PARCOURSES_IT_URL"), System.getenv("PARCOURSES_IT_KEY"))
            ?.takeIf { java.net.URI(it.url).host == "127.0.0.1" }

    @Before
    fun requireLocalSupabase() = assumeTrue("Supabase local non configuré", config != null)

    private fun newGateway(store: MemorySecureStateStore = MemorySecureStateStore()) =
        SupabaseGateway(
            createSupabaseClient(config!!, store, OkHttp.create(), Dispatchers.IO, lifecycleCallbacks = false),
            store,
        )

    private suspend fun signedIn(): SupabaseGateway = newGateway().also { it.ensureSession() }

    private suspend fun anyStoreId(gateway: RemoteGateway) = gateway.nearbyStores(43.646, 0.586, 20_000, 5).first().id

    @Test
    fun withoutSessionARequestCreatesNoAccount() =
        runBlocking<Unit> {
            val gateway = newGateway()
            try {
                gateway.fetchLists(null)
                error("attendu Unauthorized")
            } catch (_: RemoteError.Unauthorized) {
            }
            assertTrue(runCatching { gateway.currentAccountId() }.exceptionOrNull() is RemoteError.Unauthorized)
        }

    @Test
    fun concurrentCallsCreateASingleAccount() =
        runBlocking<Unit> {
            val gateway = newGateway()
            val ids = (1..4).map { async { gateway.ensureSession() } }.awaitAll()
            assertEquals(1, ids.toSet().size)
        }

    @Test
    fun theSessionSurvivesARestartThroughTheEncryptedStore() =
        runBlocking<Unit> {
            val store = MemorySecureStateStore()
            val first = newGateway(store).ensureSession()
            assertEquals(first, newGateway(store).ensureSession())
            assertNotEquals(first, signedIn().ensureSession())
        }

    @Test
    fun listsAndItemsAreIdempotentAndPrivate() =
        runBlocking<Unit> {
            val gateway = signedIn()
            val owner = gateway.ensureSession()
            val list = ListUpsert(Uuid.random(), "Courses")
            gateway.saveList(list)
            gateway.saveList(list)
            gateway.saveList(ListUpsert(list.id, "Renommée"))

            val rows = gateway.fetchLists(null)
            assertEquals(listOf(list.id), rows.map { it.id })
            assertEquals("Renommée", rows.single().name)
            assertEquals(owner, rows.single().ownerId)

            val checkedAt = kotlin.time.Instant.fromEpochMilliseconds(1_790_000_000_123)
            val item = ListItemUpsert(Uuid.random(), list.id, null, "Lait", "2", checkedAt)
            gateway.saveItem(item)
            gateway.saveItem(item)
            var items = gateway.fetchItems(null)
            assertEquals(1, items.size)
            assertEquals(checkedAt, items.single().checkedAt)

            // Un `null` vide bien la colonne.
            gateway.saveItem(item.copy(quantity = null, checkedAt = null))
            items = gateway.fetchItems(null)
            assertNull(items.single().quantity)
            assertNull(items.single().checkedAt)

            val stranger = signedIn()
            assertTrue(stranger.fetchLists(null).isEmpty())
            assertTrue(stranger.fetchItems(null).isEmpty())
            assertTrue(gateway.fetchLists(Clock.System.now() + 1.hours).isEmpty())

            gateway.deleteItem(item.id)
            gateway.deleteItem(item.id)
            gateway.deleteList(list.id)
            gateway.deleteList(list.id)
            assertTrue(gateway.fetchLists(null).isEmpty())
        }

    /** Contrat hors ligne de `docs/data-model.md`, côté gateway. */
    @Test
    fun visitAndChecksFollowTheOfflineContract() =
        runBlocking<Unit> {
            val gateway = signedIn()
            val storeId = anyStoreId(gateway)
            val categorySlug = gateway.fetchCategories().first().slug
            val productId = gateway.fetchProducts().first().id

            val startedAt = Clock.System.now() - 10.minutes
            val visit = VisitInsert(Uuid.random(), storeId, null, false, startedAt)
            gateway.createVisit(visit)
            gateway.createVisit(visit)
            assertEquals(VisitAccess.Open, gateway.visitAccess(visit.id))

            // Lot mixte produit et catégorie, rejoué : aucun doublon, aucune erreur.
            val batch =
                listOf(
                    CheckUpload(Uuid.random(), visit.id, CheckUpload.Target.Product(productId), startedAt + 10.seconds),
                    CheckUpload(
                        Uuid.random(),
                        visit.id,
                        CheckUpload.Target.Category(categorySlug),
                        startedAt + 20.seconds,
                    ),
                )
            gateway.insertChecks(batch)
            gateway.insertChecks(batch)
            gateway.insertChecks(emptyList())

            // 23514 : heure hors bornes.
            val tooEarly =
                CheckUpload(Uuid.random(), visit.id, CheckUpload.Target.Category(categorySlug), startedAt - 1.hours)
            assertTrue(
                runCatching { gateway.insertChecks(listOf(tooEarly)) }.exceptionOrNull() is RemoteError.Constraint,
            )

            // Clôture rejouable, puis 42501 sur une coche tardive.
            gateway.closeVisit(visit.id, Clock.System.now())
            gateway.closeVisit(visit.id, Clock.System.now())
            assertEquals(VisitAccess.Closed, gateway.visitAccess(visit.id))
            val late =
                CheckUpload(Uuid.random(), visit.id, CheckUpload.Target.Category(categorySlug), Clock.System.now())
            assertTrue(runCatching { gateway.insertChecks(listOf(late)) }.exceptionOrNull() is RemoteError.Forbidden)
            assertEquals(VisitAccess.NotVisible, signedIn().visitAccess(visit.id))
        }

    @Test
    fun aChangedAccountStaysReported() =
        runBlocking<Unit> {
            val store = MemorySecureStateStore()
            val gateway = newGateway(store)
            gateway.ensureSession()
            gateway.verifySession()
            store.update { it.copy(lastAccountId = Uuid.random().toString()) }
            for (call in listOf<suspend () -> Unit>(
                { gateway.ensureSession() },
                { gateway.currentAccountId() },
                { gateway.verifySession() },
                { gateway.saveList(ListUpsert(Uuid.random(), "Perdue")) },
            )) {
                assertTrue(runCatching { call() }.exceptionOrNull() is RemoteError.AccountChanged)
            }
        }

    /** #68 : la RPC supprime le compte et ses lignes, puis le serveur dit « introuvable » ; rejouée, elle réussit. */
    @Test
    fun deletingTheAccountRemovesItsRowsAndIsReportedAsGone() =
        runBlocking<Unit> {
            val gateway = signedIn()
            gateway.saveList(ListUpsert(Uuid.random(), "À effacer"))

            gateway.deleteAccount()

            // Réponse perdue : le jeton d'accès vaut encore, mais `getUser` répond « introuvable ».
            assertTrue(runCatching { gateway.verifySession() }.exceptionOrNull() is RemoteError.Unauthorized)
            // Le rafraîchissement est refusé : la session est perdue pour de bon.
            assertTrue(runCatching { gateway.deleteAccount() }.exceptionOrNull() is RemoteError.Unauthorized)
            gateway.signOutLocally()
            val fresh = gateway.ensureSession()
            assertTrue(gateway.fetchLists(null).isEmpty())
            assertEquals(fresh, gateway.currentAccountId())
        }

    @Test
    fun anUnknownCategorySlugIsAnErrorAndASharedOneIsAccepted() =
        runBlocking<Unit> {
            val gateway = signedIn()
            val visit = VisitInsert(Uuid.random(), anyStoreId(gateway), null, false, Clock.System.now())
            gateway.createVisit(visit)
            val unknown =
                CheckUpload(Uuid.random(), visit.id, CheckUpload.Target.Category("inconnue"), Clock.System.now())
            val error = runCatching { gateway.insertChecks(listOf(unknown)) }.exceptionOrNull()
            assertEquals("inconnue", (error as RemoteError.UnknownCategory).slug)
            // #36 : un identifiant de `shared/categories/` a sa ligne serveur.
            gateway.insertChecks(
                listOf(CheckUpload(Uuid.random(), visit.id, CheckUpload.Target.Category("dairy"), Clock.System.now())),
            )
        }

    @Test
    fun nearbyStoresReturnsSortedDistancesAndRejectsBadInput() =
        runBlocking<Unit> {
            val gateway = signedIn()
            val stores = gateway.nearbyStores(43.646, 0.586, 20_000, 5)
            assertTrue(stores.isNotEmpty())
            assertEquals(stores.map { it.distanceM }.sorted(), stores.map { it.distanceM })
            val error = runCatching { gateway.nearbyStores(200.0, 0.0, 1000, 1) }.exceptionOrNull()
            assertEquals("22023", (error as RemoteError.Rejected).code)
        }

    @Test
    fun storeSearchFindsByNameAndTheOrganicAisleIsReadable() =
        runBlocking<Unit> {
            val gateway = signedIn()
            val known = gateway.nearbyStores(43.646, 0.586, 20_000, 1).first()
            val found = gateway.searchStores(known.name.lowercase().take(4), 20)
            assertTrue(found.any { it.id == known.id })
            assertEquals(known.organicAisle, gateway.storeOrganicAisle(known.id))
            assertNull(gateway.storeOrganicAisle(Uuid.random()))
        }

    @Test
    fun resolveProductsKeepsOrderAndRefusesUnknownCategories() =
        runBlocking<Unit> {
            val gateway = signedIn()
            val label = "Produit test ${Uuid.random()}"
            val rows =
                gateway.resolveProducts(
                    listOf(
                        ProductResolutionRequest(label, "dairy"),
                        ProductResolutionRequest("Autre ${Uuid.random()}", "slug-inconnu"),
                    ),
                )
            assertEquals(2, rows.size)
            assertTrue(rows[0].id != null)
            assertEquals("dairy", rows[0].categorySlug)
            assertNull(rows[1].id)
            // Idempotent : le même libellé retrouve le même produit.
            assertEquals(
                rows[0].id,
                gateway.resolveProducts(listOf(ProductResolutionRequest(label, "dairy"))).single().id,
            )
        }

    @Test
    fun aStoreWithoutSnapshotAnswersNone() =
        runBlocking<Unit> {
            val gateway = signedIn()
            val response = gateway.graphSnapshot(anyStoreId(gateway), null)
            assertTrue(response is GraphSnapshotResponse.None || response is GraphSnapshotResponse.Payload)
            assertEquals(GraphSnapshotResponse.None, gateway.graphSnapshot(Uuid.random(), null))
        }
}
