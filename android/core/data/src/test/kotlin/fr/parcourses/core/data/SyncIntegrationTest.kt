package fr.parcourses.core.data

import android.content.Context
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.CategorySeed
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.SupabaseConfig
import fr.parcourses.core.network.createInMemorySupabaseGateway
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Clock

/**
 * Synchronisation complète contre le Supabase LOCAL uniquement (`scripts/integration-test.sh`) : ignorée sinon, CI
 * comprise. Deux « appareils » = deux bases Room et deux moteurs sur le même compte anonyme. Garde-fou : jamais
 * d'écriture ailleurs que sur 127.0.0.1.
 */
@RunWith(AndroidJUnit4::class)
class SyncIntegrationTest {
    private val config: SupabaseConfig? =
        SupabaseConfig
            .create(System.getenv("PARCOURSES_IT_URL"), System.getenv("PARCOURSES_IT_KEY"))
            ?.takeIf { java.net.URI(it.url).host == "127.0.0.1" }

    private val databases = mutableListOf<ParcoursesDatabase>()
    private val classifier =
        fr.parcourses.core.categorizer
            .CategoryClassifier()
    private val classify: (String) -> fr.parcourses.core.data.sync.PulledItemClassification = {
        classifier.classify(it).let { c ->
            fr.parcourses.core.data.sync
                .PulledItemClassification(c.normalized, c.categoryId)
        }
    }

    @Before
    fun requireLocalSupabase() = assumeTrue("Supabase local non configuré", config != null)

    @After
    fun close() = databases.forEach { it.close() }

    private class Device(
        val db: ParcoursesDatabase,
        val gateway: RemoteGateway,
        val engine: SyncEngine,
        val lists: RoomListRepository,
    )

    private fun device(gateway: RemoteGateway): Device {
        val db =
            ParcoursesDatabaseFactory
                .createInMemory(
                    ApplicationProvider.getApplicationContext<Context>(),
                    Dispatchers.IO,
                    AndroidSQLiteDriver(),
                ).also { databases += it }
        runBlocking { db.categories().seedIfNeeded(CategorySeed.bundled()) }
        val engine = SyncEngine(gateway, db, InMemorySyncCursors(), classify)
        return Device(db, gateway, engine, RoomListRepository(db))
    }

    @Test
    fun aListWrittenOfflineReachesTheServerAndAnotherDevice() =
        runBlocking<Unit> {
            val gateway = createInMemorySupabaseGateway(config!!)
            gateway.ensureSession()
            val phone = device(gateway)
            val tablet = device(gateway)

            val now = Clock.System.now()
            val list = phone.lists.createList("Courses IT", now)
            val milk = phone.lists.addItem(list.id, "2 laits", "lait", "2", null, "dairy", now)
            phone.lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            assertNull(phone.engine.drain())

            assertEquals(
                SyncState.SYNCED,
                phone.db
                    .lists()
                    .get(list.id)
                    ?.syncState,
            )
            assertTrue(
                phone.db
                    .outbox()
                    .all()
                    .isEmpty(),
            )

            tablet.engine.drain(pull = true)
            assertEquals(
                "Courses IT",
                tablet.db
                    .lists()
                    .get(list.id)
                    ?.name,
            )
            assertEquals(
                setOf("2 laits", "pain"),
                tablet.db
                    .items()
                    .getByList(list.id)
                    .map { it.label }
                    .toSet(),
            )
            assertEquals(
                "dairy",
                tablet.db
                    .items()
                    .get(milk.id)
                    ?.categoryId,
            )

            // Dernier écrit gagne : renommage et coche sur le téléphone, vus par la tablette.
            phone.lists.renameList(list.id, "Courses IT 2", Clock.System.now())
            phone.lists.setChecked(milk.id, Clock.System.now(), Clock.System.now())
            phone.engine.drain()
            tablet.engine.drain(pull = true)
            assertEquals(
                "Courses IT 2",
                tablet.db
                    .lists()
                    .get(list.id)
                    ?.name,
            )
            assertNotNull(
                tablet.db
                    .items()
                    .get(milk.id)
                    ?.checkedAt,
            )
        }

    @Test
    fun aFreeTextItemReceivesASharedProduct() =
        runBlocking<Unit> {
            val gateway = createInMemorySupabaseGateway(config!!)
            gateway.ensureSession()
            val device = device(gateway)
            val now = Clock.System.now()
            val list = device.lists.createList("Produits IT", now)
            val item = device.lists.addItem(list.id, "yaourt nature IT", "yaourt nature it", null, null, "dairy", now)

            device.engine.drain()

            // Serveur sans la migration `resolve_products` : l'article part quand même, sans produit.
            val stored = checkNotNull(device.db.items().get(item.id))
            assertEquals(SyncState.SYNCED, stored.syncState)
            if (stored.productId != null) {
                assertNotNull(device.db.products().get(stored.productId!!))
                val remote = gateway.fetchItems(null).single { it.id.toString() == item.id }
                assertEquals(stored.productId, remote.productId.toString())
            }
        }

    @Test
    fun aNewAccountReceivesTheReidentifiedData() =
        runBlocking<Unit> {
            val first = createInMemorySupabaseGateway(config!!)
            val oldAccount = first.ensureSession()
            val phone = device(first)
            val now = Clock.System.now()
            val list = phone.lists.createList("Avant IT", now)
            phone.lists.addItem(list.id, "riz", "riz", null, null, "savory-grocery", now)
            phone.engine.drain()

            // Session perdue : un autre compte anonyme, mêmes données locales.
            val second = createInMemorySupabaseGateway(config)
            val newAccount = second.ensureSession()
            assertNotEquals(oldAccount, newAccount)
            val remaps = mutableListOf<Map<String, String>>()
            val engine =
                SyncEngine(second, phone.db, InMemorySyncCursors().also { it.accountId = oldAccount }, classify)
            val job =
                CoroutineScope(
                    Dispatchers.Unconfined,
                ).launch { engine.remaps.collect { remaps += it.identifiers } }

            engine.drain()
            job.cancel()

            val moved =
                phone.db
                    .lists()
                    .getAll()
                    .single()
            assertNotEquals(list.id, moved.id)
            assertEquals(moved.id, remaps.single()[list.id])
            assertEquals(SyncState.SYNCED, moved.syncState)
            // Sous le nouveau compte, la liste existe désormais côté serveur ; l'ancien identifiant, non.
            val visible = second.fetchLists(null).map { it.id.toString() }
            assertTrue(moved.id in visible)
            assertTrue(list.id !in visible)
            assertEquals(newAccount, second.currentAccountId())
        }
}
