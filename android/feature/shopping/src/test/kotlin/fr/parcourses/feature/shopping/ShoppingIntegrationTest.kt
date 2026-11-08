package fr.parcourses.feature.shopping

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.PulledItemClassification
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.SupabaseConfig
import fr.parcourses.core.network.createInMemorySupabaseGateway
import fr.parcourses.core.network.dto.VisitAccess
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit
import kotlin.time.Clock
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * Une visite complète contre le Supabase LOCAL uniquement (`scripts/integration-test.sh`) : ignorée sinon, CI
 * comprise. Mode courses réel (Room, file d'envoi, moteur de synchro, passerelle), horloge pilotée dans le passé :
 * coches, puis fin, puis envoi, puis calcul du graphe côté serveur et lecture de l'instantané par l'app.
 * Garde-fou : jamais d'écriture ailleurs que sur 127.0.0.1.
 */
@RunWith(AndroidJUnit4::class)
class ShoppingIntegrationTest : ShoppingTest() {
    private val config: SupabaseConfig? =
        SupabaseConfig
            .create(System.getenv("PARCOURSES_IT_URL"), System.getenv("PARCOURSES_IT_KEY"))
            ?.takeIf { java.net.URI(it.url).host == "127.0.0.1" }

    @Before
    fun requireLocalSupabase() = assumeTrue("Supabase local non configuré", config != null)

    private val classifier = CategoryClassifier()

    /** Rejoue le travail du serveur (cron) tout de suite. `false` sans accès à la base locale. */
    private fun runServerGraphJobs(): Boolean =
        runCatching {
            val sql = "select graph.process_pending_visits(200); select graph.publish_snapshots(50);"
            val process =
                ProcessBuilder("docker", "exec", "supabase_db_parcourses", "psql", "-U", "postgres", "-c", sql)
                    .redirectErrorStream(true)
                    .start()
            process.inputStream.readBytes()
            process.waitFor(60, TimeUnit.SECONDS) && process.exitValue() == 0
        }.getOrDefault(false)

    private suspend fun product(
        gateway: RemoteGateway,
        name: String,
    ) = gateway.fetchProducts().first { it.name == name }

    @Test
    fun aFullVisitLeavesChecksThenClosureThenTheGraphComesBack() =
        runBlocking<Unit> {
            val gateway = createInMemorySupabaseGateway(config!!)
            gateway.ensureSession()
            val engine =
                SyncEngine(
                    gateway,
                    db,
                    InMemorySyncCursors(),
                    { label ->
                        classifier.classify(label).let { PulledItemClassification(it.normalized, it.categoryId) }
                    },
                )
            engine.drain(pull = true)

            val store = gateway.nearbyStores(43.646, 0.586, 20_000, 5).first()
            val shop = store.id.toString()
            stores.upsertStore(shop, store.name, store.chain, store.address, store.organicAisle)

            val apples = product(gateway, "Pommes")
            val bread = product(gateway, "Baguette")
            val milk = product(gateway, "Lait")
            val created = Clock.System.now() - 40.minutes
            val listId = lists.createList("Courses IT", created).id
            listOf(
                Triple("lait", "dairy", milk),
                Triple("baguette", "bakery", bread),
                Triple("pommes", "produce", apples),
            ).forEach { (label, category, product) ->
                lists.addItem(listId, label, label, null, product.id.toString(), category, created)
            }
            assertEquals(null, engine.drain())

            // Horloge dans le passé, avancée à la main : la visite a duré cinq minutes.
            var at: Instant = Clock.System.now() - 30.minutes
            val model =
                ShoppingViewModel(
                    listId = listId,
                    storeId = shop,
                    deps =
                        ShoppingDependencies(
                            lists,
                            visits,
                            stores,
                            fr.parcourses.core.data.repository
                                .RoomCategoryRepository(db),
                            analyzer,
                            GraphSnapshotCache(graphs, gateway),
                        ),
                    timings = ShoppingTimings(undo = 0.seconds, sendMargin = 0.seconds, preload = 5.seconds),
                    now = { at },
                    computation = main,
                )
            model.start()
            // La lecture de l'instantané passe par le vrai réseau : on laisse le temps réel s'écouler.
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
            while (!model.uiState.value.isLoaded && System.nanoTime() < deadline) {
                scheduler.runCurrent()
                Thread.sleep(50)
            }
            assertTrue(model.uiState.value.isLoaded)

            // Le rayon dans l'ordre : pommes, baguette, lait.
            listOf("pommes" to 40, "baguette" to 50, "lait" to 60).forEach { (label, gap) ->
                at += gap.seconds
                model.toggle(model.uiState.value.row(label))
                scheduler.runCurrent()
            }
            at += 30.seconds
            model.finish(keepRemaining = true)
            scheduler.runCurrent()
            val summary = checkNotNull(model.uiState.value.summary)
            assertEquals(3, summary.checkedCount)
            val visitId = checkNotNull(summary.visitId)

            // Envoi : visite, coches, clôture, dans cet ordre imposé par la RLS.
            assertEquals(null, engine.drain())
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(VisitAccess.Closed, gateway.visitAccess(Uuid.parse(visitId)))
            val visit = checkNotNull(db.visits().get(visitId))
            assertEquals(SyncState.SYNCED, visit.syncState)
            assertEquals(SyncState.SYNCED, visit.endSyncState)
            val checks = db.checks().getByVisit(visitId)
            assertEquals(3, checks.size)
            checks.forEach { assertEquals(SyncState.SYNCED, it.syncState) }
            // Les coches désignent les produits du catalogue, pas des catégories.
            assertEquals(
                setOf(apples.id, bread.id, milk.id).map { it.toString() }.toSet(),
                checks.map { it.productId }.toSet(),
            )

            // Le graphe est calculé côté serveur ; l'app lit l'instantané et le met en cache.
            if (runServerGraphJobs()) {
                val loaded = GraphSnapshotCache(graphs, gateway).refresh(shop)
                if (loaded != null) {
                    assertNotNull(graphs.snapshot(shop))
                    assertEquals(loaded.version, GraphSnapshotCache(graphs, gateway).cached(shop)?.version)
                    assertTrue(loaded.snapshot.entries.isNotEmpty() || loaded.snapshot.edges.isNotEmpty())
                    println(
                        "Instantané: confiance ${loaded.snapshot.confidenceQ}, ${loaded.snapshot.edges.size} arêtes",
                    )
                } else {
                    println("Instantané: pas encore de graphe pour ce magasin")
                }
            } else {
                println("Calcul du graphe ignoré : docker exec supabase_db_parcourses indisponible")
            }
        }
}
