package fr.parcourses.core.data

import android.content.Context
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountLink
import fr.parcourses.core.data.account.AccountLinkHost
import fr.parcourses.core.data.account.AccountLinkOutcome
import fr.parcourses.core.data.account.InMemoryAccountKindFlag
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.sharing.AcceptOutcome
import fr.parcourses.core.data.sharing.AccessChange
import fr.parcourses.core.data.sharing.RealtimeSignals
import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.core.data.sharing.SharingRepository
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.PulledItemClassification
import fr.parcourses.core.data.sync.SyncDependencies
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.CategorySeed
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.SupabaseConfig
import fr.parcourses.core.network.SupabaseGateway
import fr.parcourses.core.network.createInMemorySupabaseGateway
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds
import kotlin.uuid.Uuid

/**
 * Partage de bout en bout contre le Supabase LOCAL uniquement (`scripts/integration-test.sh`, Mailpit et Realtime
 * démarrés) : ignoré sinon, CI comprise. Deux comptes e-mail, chacun sur son « appareil » (base Room, moteur, canal
 * temps réel) :
 * - invitation par la RPC `create_invitation` (« Copier le lien », sans e-mail : l'image Edge Runtime manque en
 *   local, et l'Edge Function est couverte par `supabase/tests/e2e/sharing.test.ts`) ;
 * - acceptation par `my_invitations`, puis une seconde liste par le lien `parcourses://invitation#<jeton>` ;
 * - une coche de l'invitée arrive chez le propriétaire par un signal Realtime ;
 * - rôle abaissé (lecture seule, modification jetée), puis retrait (liste retirée de l'appareil).
 */
@RunWith(AndroidJUnit4::class)
class SharingIntegrationTest {
    private val config: SupabaseConfig? =
        SupabaseConfig
            .create(System.getenv("PARCOURSES_IT_URL"), System.getenv("PARCOURSES_IT_KEY"))
            ?.takeIf { java.net.URI(it.url).host == "127.0.0.1" }

    private val databases = mutableListOf<ParcoursesDatabase>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val classifier =
        fr.parcourses.core.categorizer
            .CategoryClassifier()
    private val classify: (String) -> PulledItemClassification = {
        classifier.classify(it).let { c -> PulledItemClassification(c.normalized, c.categoryId) }
    }

    @Before
    fun requireLocalStack() {
        assumeTrue("Supabase local non configuré", config != null)
        assumeTrue("Mailpit non configuré", Mailpit.isConfigured)
    }

    @After
    fun close() {
        scope.cancel()
        databases.forEach { it.close() }
    }

    private class Device(
        val db: ParcoursesDatabase,
        val gateway: SupabaseGateway,
        val engine: SyncEngine,
        val lists: RoomListRepository,
        val cursors: InMemorySyncCursors,
        val sharing: SharingRepository,
        val changes: MutableList<AccessChange>,
    )

    /** Un appareil d'un compte e-mail : liaison par le code lu dans Mailpit, puis première descente. */
    private suspend fun emailDevice(
        tag: String,
        name: String,
    ): Pair<Device, String> {
        val gateway = createInMemorySupabaseGateway(config!!)
        gateway.ensureSession()
        val db =
            ParcoursesDatabaseFactory
                .createInMemory(
                    ApplicationProvider.getApplicationContext<Context>(),
                    Dispatchers.IO,
                    AndroidSQLiteDriver(),
                ).also { databases += it }
        db.categories().seedIfNeeded(CategorySeed.bundled())
        val cursors = InMemorySyncCursors()
        val changes = mutableListOf<AccessChange>()
        val engine =
            SyncEngine(
                gateway,
                db,
                cursors,
                classify,
                SyncDependencies(accountKind = { AccountKind.Email }, onAccessChange = { changes += it }),
            )
        val device =
            Device(
                db,
                gateway,
                engine,
                RoomListRepository(db),
                cursors,
                SharingRepository(gateway, db, pull = { engine.drain(pull = true) }, access = { engine }),
                changes,
            )
        engine.drain(pull = true)
        val email = Mailpit.address(tag)
        val link = link(device)
        val since = java.time.Instant.now()
        link.requestCode(email, name)
        link.verify(Mailpit.code(email, since))
        assertEquals(AccountLinkOutcome.Linked, link.state.value.outcome)
        return device to email
    }

    private fun link(device: Device): AccountLink =
        AccountLink(
            device.gateway,
            InMemoryAccountKindFlag(),
            object : AccountLinkHost {
                override suspend fun adoptAccount(expected: Uuid): Int? = device.engine.adoptSessionAccount(expected)

                override fun sessionDidChange() = Unit

                override suspend fun suspendSync() = device.engine.suspend()

                override fun resumeSync() = device.engine.resume()

                override suspend fun dataAccount(): Uuid? = device.cursors.accountId

                override suspend fun pendingChanges(): Int = device.db.outbox().pendingCount()

                override suspend fun adoptDataAccount(account: Uuid) = device.cursors.adopt(account, AccountKind.Email)

                override suspend fun purgeLocalData() = error("pas de changement de compte e-mail ici")
            },
            isOnline = { true },
        )

    @Test
    fun twoEmailAccountsShareAListInRealTime() =
        runBlocking<Unit> {
            val (owner, _) = emailDevice("owner", "Hadrien IT")
            // `max_frequency` local de 1 s entre deux codes.
            delay(2.seconds)
            val (member, memberEmail) = emailDevice("member", "Léa IT")

            // Le propriétaire crée sa liste et invite par la RPC (lien copié, aucun e-mail).
            val now = Clock.System.now()
            val list = owner.lists.createList("Partagée 87.6", now)
            val milk = owner.lists.addItem(list.id, "lait", "lait", "1", null, "dairy", now)
            owner.engine.drain()
            val link = owner.sharing.invitationLink(list.id, memberEmail, ListRole.Editor)
            assertNotNull(SharingDecisions.parseInvitationLink(link, null))

            // L'invitée la retrouve par son adresse et l'accepte : la liste descend avant d'être ouverte.
            val received = member.sharing.myInvitations()
            val invitation = received.single { it.listId.toString() == list.id }
            assertEquals("Partagée 87.6", invitation.listName)
            assertEquals("Hadrien IT", invitation.inviterName)
            val accepted = member.sharing.acceptInvitation(invitation.id)
            assertEquals(AcceptOutcome.Joined, SharingDecisions.acceptOutcome(accepted.status))
            assertEquals(list.id, accepted.listId?.toString())
            assertEquals(
                ListRole.Editor,
                member.db
                    .lists()
                    .get(list.id)
                    ?.role,
            )
            assertEquals(
                "lait",
                member.db
                    .items()
                    .get(milk.id)
                    ?.label,
            )
            assertEquals(
                listOf("Hadrien IT", "Léa IT"),
                member.db
                    .participants()
                    .get(list.id)
                    .map { it.displayName },
            )

            // Le propriétaire écoute son canal privé : la coche de l'invitée le réveille.
            val pulls = AtomicInteger()
            val signals =
                RealtimeSignals(
                    source = owner.gateway,
                    accountId = { owner.gateway.currentAccountId() },
                    accountKind = MutableStateFlow(AccountKind.Email),
                    requestPull = { pulls.incrementAndGet() },
                    scope = scope,
                )
            signals.foreground()
            withTimeout(15.seconds) { while (!signals.isConnected.value) delay(100) }
            val connectedPulls = pulls.get()
            member.lists.setChecked(milk.id, Clock.System.now(), Clock.System.now())
            member.engine.drain()
            withTimeout(15.seconds) { while (pulls.get() == connectedPulls) delay(100) }
            owner.engine.drain(pull = true)
            assertNotNull(
                owner.db
                    .items()
                    .get(milk.id)
                    ?.checkedAt,
            )
            // La dernière modification est celle de l'invitée : son initiale sur l'article, chez le propriétaire.
            assertEquals(
                member.gateway.currentAccountId().toString(),
                owner.db
                    .items()
                    .get(milk.id)
                    ?.updatedBy,
            )
            signals.background()

            // Seconde liste, acceptée par le lien.
            val second = owner.lists.createList("Par lien 87.6", Clock.System.now())
            owner.engine.drain()
            val token =
                checkNotNull(
                    SharingDecisions.parseInvitationLink(
                        owner.sharing.invitationLink(second.id, memberEmail, ListRole.Viewer),
                        null,
                    ),
                )
            val preview = member.sharing.previewInvitation(token)
            assertEquals("pending", preview.status)
            assertEquals(true, preview.emailMatches)
            val byLink = member.sharing.acceptInvitation(token)
            assertEquals(AcceptOutcome.Joined, SharingDecisions.acceptOutcome(byLink.status))
            assertEquals(
                ListRole.Viewer,
                member.db
                    .lists()
                    .get(second.id)
                    ?.role,
            )

            // Rôle abaissé : la modification de l'invitée est jetée, la liste passe en lecture seule.
            val memberId = member.gateway.currentAccountId().toString()
            owner.sharing.setMemberRole(list.id, memberId, ListRole.Viewer)
            member.lists.setChecked(milk.id, null, Clock.System.now())
            member.engine.drain()
            assertEquals(
                ListRole.Viewer,
                member.db
                    .lists()
                    .get(list.id)
                    ?.role,
            )
            assertTrue(
                member.db
                    .outbox()
                    .all()
                    .isEmpty(),
            )
            assertNotNull(
                member.db
                    .items()
                    .get(milk.id)
                    ?.checkedAt,
            )
            assertTrue(member.changes.any { it is AccessChange.Downgraded && it.listId == list.id })

            // Retrait : la liste quitte l'appareil de l'invitée, avec le message.
            owner.sharing.removeMember(list.id, memberId)
            member.engine.drain(pull = true)
            assertNull(member.db.lists().get(list.id))
            assertNull(member.db.items().get(milk.id))
            assertTrue(member.changes.contains(AccessChange.Removed(list.id, "Partagée 87.6")))
            // L'autre liste partagée reste.
            assertNotNull(member.db.lists().get(second.id))
        }
}
