package fr.parcourses.core.data

import android.content.Context
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountLink
import fr.parcourses.core.data.account.AccountLinkHost
import fr.parcourses.core.data.account.AccountLinkPhase
import fr.parcourses.core.data.account.InMemoryAccountKindFlag
import fr.parcourses.core.data.outbox.ItemFields
import fr.parcourses.core.data.outbox.OutboxQueue
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
import fr.parcourses.core.network.dto.EmailCodePurpose
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Clock
import kotlin.uuid.Uuid

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

    private fun link(device: Device): AccountLink =
        AccountLink(
            device.gateway,
            InMemoryAccountKindFlag(),
            object : AccountLinkHost {
                override suspend fun adoptAccount(expected: Uuid): Int? = device.engine.adoptSessionAccount(expected)

                override fun sessionDidChange() = Unit
            },
            isOnline = { true },
        )

    /**
     * #87 (lot 87.5), deux appareils d'un même compte e-mail : le téléphone lie une adresse par le code lu dans
     * Mailpit (même compte) ; la tablette, anonyme avec sa propre liste, demande la même adresse (`email_exists`), se
     * connecte par code et ajoute sa liste au compte. Ensuite deux champs modifiés chacun de son côté sont gardés tous
     * les deux, et une suppression faite sur le téléphone quitte la tablette par sa pierre tombale.
     */
    @Test
    fun twoDevicesOfOneEmailAccountKeepEachFieldAndPropagateDeletions() =
        runBlocking<Unit> {
            assumeTrue("Mailpit non configuré", Mailpit.isConfigured)
            val email = Mailpit.address("sync")
            val phoneGateway = createInMemorySupabaseGateway(config!!)
            val account = phoneGateway.ensureSession()
            val phone = device(phoneGateway)
            val now = Clock.System.now()
            val list = phone.lists.createList("Partagée IT", now)
            val milk = phone.lists.addItem(list.id, "lait", "lait", "1", null, "dairy", now)
            val bread = phone.lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            phone.engine.drain()

            // Liaison : même compte, rien à reprendre.
            val phoneLink = link(phone)
            var since = java.time.Instant.now()
            phoneLink.requestCode(email, "Léa IT")
            assertEquals(EmailCodePurpose.Link, phoneLink.state.value.purpose)
            phoneLink.verify(Mailpit.code(email, since))
            assertEquals(AccountLinkPhase.Done, phoneLink.state.value.phase)
            assertFalse(phoneLink.state.value.welcomeBack)
            assertEquals(account, phoneGateway.currentAccountId())
            assertEquals("Léa IT", phoneGateway.displayName())

            // Tablette : anonyme, sa liste, puis l'adresse déjà prise.
            val tabletGateway = createInMemorySupabaseGateway(config)
            val anonymous = tabletGateway.ensureSession()
            val tablet = device(tabletGateway)
            val own = tablet.lists.createList("Tablette IT", Clock.System.now())
            tablet.lists.addItem(own.id, "riz", "riz", null, null, "savory-grocery", Clock.System.now())
            tablet.engine.drain()
            val tabletLink = link(tablet)
            since = java.time.Instant.now()
            tabletLink.requestCode(email, "Autre")
            assertEquals(EmailCodePurpose.SignIn, tabletLink.state.value.purpose)
            tabletLink.verify(Mailpit.code(email, since))
            val welcome = tabletLink.state.value
            assertEquals(AccountLinkPhase.Done, welcome.phase)
            assertTrue(welcome.welcomeBack)
            assertEquals(1, welcome.listsAdded)
            // Le prénom du compte existant est gardé.
            assertEquals("Léa IT", welcome.displayName)
            assertNotEquals(anonymous, account)

            tablet.engine.drain(pull = true)
            phone.engine.drain(pull = true)
            val names = setOf("Partagée IT", "Tablette IT")
            assertEquals(
                names,
                phone.db
                    .lists()
                    .getAll()
                    .map { it.name }
                    .toSet(),
            )
            assertEquals(
                names,
                tablet.db
                    .lists()
                    .getAll()
                    .map { it.name }
                    .toSet(),
            )
            assertEquals(
                account.toString(),
                tablet.db
                    .lists()
                    .get(list.id)
                    ?.ownerId,
            )

            // Deux champs du même article, un par appareil : les deux gagnent.
            phone.lists.setChecked(milk.id, Clock.System.now(), Clock.System.now())
            val onTablet = checkNotNull(tablet.db.items().get(milk.id))
            assertTrue(onTablet.isOnServer)
            tablet.db.items().upsert(onTablet.copy(quantity = "3", syncState = SyncState.PENDING))
            OutboxQueue(tablet.db.outbox()).enqueueUpsert(
                checkNotNull(tablet.db.items().get(milk.id)),
                Clock.System.now(),
                listOf(ItemFields.QUANTITY),
            )
            phone.engine.drain()
            tablet.engine.drain()
            phone.engine.drain(pull = true)
            tablet.engine.drain(pull = true)
            for (device in listOf(phone, tablet)) {
                val item = checkNotNull(device.db.items().get(milk.id))
                assertNotNull(item.checkedAt)
                assertEquals("3", item.quantity)
            }

            // Suppression sur le téléphone : la tablette l'apprend par la pierre tombale.
            phone.lists.deleteItem(bread.id, Clock.System.now())
            phone.engine.drain()
            assertNotNull(tablet.db.items().get(bread.id))
            tablet.engine.drain(pull = true)
            assertNull(tablet.db.items().get(bread.id))
            assertNotNull(tablet.db.items().get(milk.id))

            phoneGateway.deleteAccount()
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
                // Produit privé (#69) : l'article garde son produit, mais le cache ne reprend que le catalogue publié.
                // Ce test revendique le libellé depuis un compte neuf à chaque passage : il finit publié, présent ou non.
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
            assertEquals(moved.id, remaps.last()[list.id])
            assertEquals(SyncState.SYNCED, moved.syncState)
            // Sous le nouveau compte, la liste existe désormais côté serveur ; l'ancien identifiant, non.
            val visible = second.fetchLists(null).map { it.id.toString() }
            assertTrue(moved.id in visible)
            assertTrue(list.id !in visible)
            assertEquals(newAccount, second.currentAccountId())
        }
}
