package fr.parcourses.feature.shopping

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.data.account.AccountDeletion
import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.data.account.AccountDeletionOutcome
import fr.parcourses.core.data.account.DeletionGuardedGateway
import fr.parcourses.core.data.account.InMemoryAccountDeletionFlag
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.repository.CheckSubject
import fr.parcourses.core.data.repository.RoomCategoryRepository
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.PulledItemClassification
import fr.parcourses.core.data.sync.SyncDependencies
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.SupabaseConfig
import fr.parcourses.core.network.createInMemorySupabaseGateway
import fr.parcourses.core.network.dto.RemoteProduct
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
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * Visites complètes contre le Supabase LOCAL uniquement (`scripts/integration-test.sh`) : ignorées sinon, CI
 * comprise. Mode courses réel (Room, file d'envoi, moteur de synchro, passerelle) : coches, puis fin, puis envoi,
 * puis calcul du graphe par le serveur et lecture de l'instantané. Garde-fou : jamais d'écriture ailleurs que sur
 * 127.0.0.1, et le calcul du graphe ne vise que la base du Supabase local de ce projet (port 56322).
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

    private fun run(vararg command: String): String? =
        runCatching {
            val process = ProcessBuilder(*command).redirectErrorStream(true).start()
            val out = process.inputStream.readBytes().decodeToString()
            out.takeIf { process.waitFor(60, TimeUnit.SECONDS) && process.exitValue() == 0 }
        }.getOrNull()

    /**
     * La base locale, si elle est joignable : le démon Docker doit être celui de cette machine (socket local, ni
     * `DOCKER_HOST` distant ni autre contexte, voir [isLocalDockerEndpoint]), et le conteneur doit publier son
     * Postgres sur le port local 56322, celui du Supabase de ce projet (`supabase/config.toml`). Sinon aucune
     * commande n'est envoyée.
     */
    private val localDatabase: String? by lazy {
        val endpoint = run("docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}")
        if (!isLocalDockerEndpoint(System.getenv("DOCKER_HOST"), endpoint)) return@lazy null
        val ports = run("docker", "port", DB_CONTAINER, "5432").orEmpty()
        DB_CONTAINER.takeIf { ports.lines().any { it.trim().endsWith(":$DB_PORT") } }
    }

    private fun sql(
        container: String,
        query: String,
    ): String = checkNotNull(run("docker", "exec", container, "psql", "-U", "postgres", "-tAc", query)) { query }.trim()

    /**
     * Rejoue tout de suite le travail du cron : apprentissage des visites closes, puis publication. Renvoie `true`
     * si la visite [visitId] a été apprise. Le serveur n'apprend une visite qu'après minuit, heure de Paris (#70) :
     * l'apprentissage est joué le lendemain (minuit + 36 h : toujours le lendemain à Paris, même un jour de 25 h).
     */
    private fun runServerGraphJobs(
        container: String,
        visitId: String,
    ): Boolean {
        sql(
            container,
            "select graph.process_pending_visits(200, date_trunc('day', now(), 'Europe/Paris') + interval '36 hours')",
        )
        // Publication forcée (#70) : le public compté doit inclure le compte de ce passage, même relancé dans l'heure.
        sql(container, "select graph.publish_snapshots(50, now(), interval '0')")
        // L'identifiant vient de la base locale de l'app (UUID) : aucune entrée extérieure dans la requête.
        require(Uuid.parse(visitId).toString() == visitId)
        return sql(container, "select processed_at is not null from public.visits where id = '$visitId'") == "t"
    }

    private suspend fun product(
        gateway: RemoteGateway,
        name: String,
    ) = gateway.fetchProducts().first { it.name == name }

    private fun engine(gateway: RemoteGateway) =
        SyncEngine(
            gateway,
            db,
            InMemorySyncCursors(),
            { label -> classifier.classify(label).let { PulledItemClassification(it.normalized, it.categoryId) } },
        )

    private class Fixture(
        val gateway: RemoteGateway,
        val engine: SyncEngine,
        val shop: String,
        val listId: String,
        val products: Map<String, RemoteProduct>,
    )

    private suspend fun fixture(createdAt: Instant): Fixture {
        val gateway = createInMemorySupabaseGateway(config!!)
        gateway.ensureSession()
        val engine = engine(gateway)
        engine.drain(pull = true)
        val store = gateway.nearbyStores(43.646, 0.586, 20_000, 5).first()
        val shop = store.id.toString()
        stores.upsertStore(shop, store.name, store.chain, store.address, store.organicAisle)
        val products =
            mapOf("lait" to "Lait", "baguette" to "Baguette", "pommes" to "Pommes")
                .mapValues { (_, name) -> product(gateway, name) }
        val listId = lists.createList("Courses IT", createdAt).id
        listOf("lait" to "dairy", "baguette" to "bakery", "pommes" to "produce").forEach { (label, category) ->
            lists.addItem(listId, label, label, null, products.getValue(label).id.toString(), category, createdAt)
        }
        assertEquals(null, engine.drain())
        return Fixture(gateway, engine, shop, listId, products)
    }

    private fun shoppingModel(
        fixture: Fixture,
        undo: Duration,
        now: () -> Instant,
    ) = tracked {
        ShoppingViewModel(
            listId = fixture.listId,
            storeId = fixture.shop,
            deps =
                ShoppingDependencies(
                    lists,
                    visits,
                    stores,
                    RoomCategoryRepository(db),
                    analyzer,
                    GraphSnapshotCache(graphs, fixture.gateway),
                ),
            timings = ShoppingTimings(undo = undo, sendMargin = if (undo > Duration.ZERO) 1.seconds else 0.seconds),
            now = now,
            computation = main,
        )
    }

    /** La lecture de l'instantané passe par le vrai réseau : on laisse le temps réel s'écouler. */
    private fun ShoppingViewModel.awaitLoaded() {
        start()
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
        while (!uiState.value.isLoaded && System.nanoTime() < deadline) {
            scheduler.runCurrent()
            Thread.sleep(50)
        }
        assertTrue(uiState.value.isLoaded)
    }

    @Test
    fun aFullVisitLeavesChecksThenClosureThenTheGraphComesBack() =
        runBlocking<Unit> {
            val fixture = fixture(Clock.System.now() - 40.minutes)
            // Horloge dans le passé, avancée à la main : la visite a duré cinq minutes.
            var at: Instant = Clock.System.now() - 30.minutes
            val model = shoppingModel(fixture, undo = Duration.ZERO) { at }
            model.awaitLoaded()

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
            assertEquals(null, fixture.engine.drain())
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(VisitAccess.Closed, fixture.gateway.visitAccess(Uuid.parse(visitId)))
            val visit = checkNotNull(db.visits().get(visitId))
            assertEquals(SyncState.SYNCED, visit.syncState)
            assertEquals(SyncState.SYNCED, visit.endSyncState)
            val checks = db.checks().getByVisit(visitId)
            assertEquals(3, checks.size)
            checks.forEach { assertEquals(SyncState.SYNCED, it.syncState) }
            // Les coches désignent les produits du catalogue, pas des catégories.
            assertEquals(
                fixture.products.values
                    .map { it.id.toString() }
                    .toSet(),
                checks.map { it.productId }.toSet(),
            )

            // Le graphe est calculé côté serveur, puis l'app lit l'instantané et le met en cache. Obligatoire dès
            // que la base locale est joignable.
            val database = localDatabase
            assumeTrue("base locale (port $DB_PORT) injoignable : calcul du graphe non vérifié", database != null)
            assertTrue("visite apprise par le serveur", runServerGraphJobs(database!!, visitId))
            // Le serveur republie un magasin au plus une fois par heure : « inchangé » laisse le cache, déjà à jour.
            val cache = GraphSnapshotCache(graphs, fixture.gateway)
            val loaded = cache.refresh(fixture.shop) ?: cache.cached(fixture.shop)
            checkNotNull(loaded) { "aucun instantané du graphe pour ce magasin" }
            assertNotNull(graphs.snapshot(fixture.shop))
            assertTrue(loaded.snapshot.confidenceQ > 0)
            assertTrue(loaded.snapshot.edges.isNotEmpty())

            // Contribution (A9) : la visite suivante dans ce magasin part de l'instantané publié, et son résumé
            // remercie avec la confiance du serveur (`store_stats.confidence_q`, en millièmes).
            val next =
                shoppingModel(fixture.copyWithList(nextList(fixture)), undo = Duration.ZERO) { Clock.System.now() }
            next.awaitLoaded()
            next.toggle(next.uiState.value.row("lait"))
            scheduler.runCurrent()
            next.finish(keepRemaining = true)
            scheduler.runCurrent()
            val end = checkNotNull(next.uiState.value.summary)
            val percent = (loaded.snapshot.confidenceQ / 10).toInt()
            val expected =
                if (loaded.snapshot.confidenceQ >= loaded.params.confThresholdQ) {
                    RouteKnowledge.Learned(percent)
                } else {
                    RouteKnowledge.Learning(percent)
                }
            assertEquals(expected, end.knowledge)
            assertNotNull(end.visitId)
            assertEquals(null, fixture.engine.drain())
        }

    private fun Fixture.copyWithList(listId: String) = Fixture(gateway, engine, shop, listId, products)

    private suspend fun nextList(fixture: Fixture): String {
        val at = Clock.System.now()
        val listId = lists.createList("Courses IT, suite", at).id
        val milk =
            fixture.products
                .getValue("lait")
                .id
                .toString()
        lists.addItem(listId, "lait", "lait", null, milk, "dairy", at)
        return listId
    }

    @Test
    fun anUndoneCheckNeverReachesTheServerAndTheRestLeavesAfterTheUndoWindow() =
        runBlocking<Unit> {
            val fixture = fixture(Clock.System.now() - 10.minutes)
            // Horloge réelle : la retenue des coches (annulation 2 s + marge 1 s) est celle de la file.
            val model = shoppingModel(fixture, undo = 2.seconds) { Clock.System.now() }
            model.awaitLoaded()

            model.toggle(model.uiState.value.row("pommes"))
            scheduler.runCurrent()
            model.toggle(model.uiState.value.row("baguette"))
            scheduler.runCurrent()
            model.performUndo()
            scheduler.runCurrent()

            // Pendant la fenêtre d'annulation, rien ne part.
            fixture.engine.drain()
            assertTrue(db.checks().getAll().all { it.syncState == SyncState.PENDING })
            val visitId = checkNotNull(visits.openVisit()).id
            assertEquals(VisitAccess.NotVisible, fixture.gateway.visitAccess(Uuid.parse(visitId)))

            Thread.sleep(3_500)
            model.finish(keepRemaining = true)
            scheduler.runCurrent()
            assertEquals(null, fixture.engine.drain())

            assertEquals(VisitAccess.Closed, fixture.gateway.visitAccess(Uuid.parse(visitId)))
            val checks = db.checks().getByVisit(visitId)
            // Seule la coche non annulée existe, et elle est partie.
            assertEquals(
                listOf(
                    fixture.products
                        .getValue("pommes")
                        .id
                        .toString(),
                ),
                checks.map { it.productId },
            )
            assertEquals(SyncState.SYNCED, checks.single().syncState)
            assertTrue(db.outbox().all().isEmpty())
        }

    /** Lignes du compte [account] sur le serveur, table par table (et le compte lui-même). */
    private fun serverRows(
        container: String,
        account: Uuid,
    ): Map<String, Int> {
        // L'identifiant vient de la passerelle (UUID) : aucune entrée extérieure dans la requête.
        val id = Uuid.parse(account.toString()).toString()
        val queries =
            mapOf(
                "auth.users" to "select count(*) from auth.users where id = '$id'",
                "lists" to "select count(*) from public.lists where owner_id = '$id'",
                "list_items" to
                    "select count(*) from public.list_items i join public.lists l on l.id = i.list_id " +
                    "where l.owner_id = '$id'",
                "visits" to "select count(*) from public.visits where user_id = '$id'",
                "checks" to
                    "select count(*) from public.checks c join public.visits v on v.id = c.visit_id " +
                    "where v.user_id = '$id'",
            )
        return queries.mapValues { (_, query) -> sql(container, query).toInt() }
    }

    /**
     * « Supprimer mes données » (#68) sur la pile locale : une liste, une visite cochée, puis la suppression. En base,
     * l'ancien compte et ses lignes n'existent plus, et le nouveau compte anonyme ne reçoit rien (aucune reprise de
     * compte, aucun renvoi).
     */
    @Test
    fun deletingTheAccountLeavesNothingOnTheServerAndNothingForTheNewAccount() =
        runBlocking<Unit> {
            val database = localDatabase
            assumeTrue("base locale (port $DB_PORT) injoignable : suppression non vérifiable en base", database != null)
            val flag = InMemoryAccountDeletionFlag()
            val remote = DeletionGuardedGateway(createInMemorySupabaseGateway(config!!), flag)
            val cursors = InMemorySyncCursors()
            fun newEngine() =
                SyncEngine(
                    remote,
                    db,
                    cursors,
                    { classifier.classify(it).let { c -> PulledItemClassification(c.normalized, c.categoryId) } },
                    SyncDependencies(isAccountDeletionPending = { flag.isPending }),
                )
            var engine = newEngine()
            remote.ensureSession()
            engine.drain(pull = true)
            val old = remote.currentAccountId()

            // Une liste, puis une visite avec une coche, envoyées à l'ancien compte.
            val shop =
                remote
                    .nearbyStores(43.646, 0.586, 20_000, 1)
                    .first()
                    .id
                    .toString()
            val milk = product(remote, "Lait")
            val start = Clock.System.now() - 10.minutes
            val listId = lists.createList("Courses IT", start).id
            val item = lists.addItem(listId, "lait", "lait", null, milk.id.toString(), "dairy", start)
            val visit = visits.startVisit(shop, listId, false, start)
            visits.checkItem(visit.id, item.id, CheckSubject.Product(milk.id.toString()), start + 1.minutes)
            assertEquals(null, engine.drain())
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(
                mapOf("auth.users" to 1, "lists" to 1, "list_items" to 1, "visits" to 1, "checks" to 1),
                serverRows(database!!, old),
            )

            val host =
                object : AccountDeletionHost {
                    override suspend fun suspendSync() = engine.suspend()

                    override suspend fun endShopping() = Unit

                    override fun resumeSync() = engine.resume()

                    override suspend fun rebuild() {
                        engine = newEngine()
                    }
                }
            val deletion = AccountDeletion(remote, flag, LocalDataPurge(db, cursors), host, isOnline = { true })

            assertEquals(AccountDeletionOutcome.Deleted, deletion.run())

            assertTrue(serverRows(database, old).values.all { it == 0 })
            val fresh = remote.currentAccountId()
            assertTrue(fresh != old)
            assertTrue(db.lists().getAll().isEmpty())
            // Synchronisation sur le nouveau compte : rien ne repart.
            engine.drain(pull = true)
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(
                mapOf("auth.users" to 1, "lists" to 0, "list_items" to 0, "visits" to 0, "checks" to 0),
                serverRows(database, fresh),
            )
        }

    private companion object {
        const val DB_CONTAINER = "supabase_db_parcourses"
        const val DB_PORT = 56322
    }
}
