package fr.parcourses.core.data.sharing

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.DataTest
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.SyncDependencies
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.SharingRequestError
import fr.parcourses.core.network.dto.InvitationAcceptance
import fr.parcourses.core.network.dto.ListItemRow
import fr.parcourses.core.network.dto.ListMemberRow
import fr.parcourses.core.network.dto.ListRow
import fr.parcourses.core.network.dto.ProfileRow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.minutes
import kotlin.uuid.Uuid

/**
 * Partage côté données (#87, lot 87.6) : `refreshAccess` relit `list_sharing` (accès retiré, lecture seule), les
 * personnes et le rôle arrivent à la descente, et la passerelle du partage traduit ses refus.
 */
@RunWith(AndroidJUnit4::class)
class SharingSyncTest : DataTest() {
    private val gateway = fakeGateway()
    private val cursors = InMemorySyncCursors()
    private val changes = mutableListOf<AccessChange>()
    private val itemsSent = mutableListOf<String>()
    private val emailDependencies =
        SyncDependencies(
            now = { now },
            jitter = { 1.0 },
            isOnline = { online },
            accountKind = { AccountKind.Email },
            onAccessChange = { changes += it },
            onItemsSent = { itemsSent += it },
        )
    private val engine by lazy { SyncEngine(gateway, db, cursors, classify, emailDependencies) }
    private val repository by lazy { RoomListRepository(db) }
    private val sharing by lazy {
        SharingRepository(gateway, db, isOnline = { online }, pull = { engine.drain(pull = true) }, access = { engine })
    }

    private val me get() = gateway.account
    private val owner = Uuid.random()

    /** Une liste de [owner] dont je suis [role], avec un article, descendue du serveur. */
    private suspend fun sharedList(role: ListRole = ListRole.Editor): Pair<String, String> {
        val listId = Uuid.random()
        val itemId = Uuid.random()
        gateway.remoteLists = listOf(ListRow(listId, owner, "Courses de la semaine", now, now))
        gateway.remoteItems = listOf(ListItemRow(itemId, listId, null, "lait", "1", null, now, now, owner))
        gateway.listMembers = listOf(ListMemberRow(listId, me, role, owner, now, now))
        gateway.profiles = listOf(ProfileRow(owner, "Hadrien", now, now), ProfileRow(me, "Léa", now, now))
        gateway.roles[listId] = role
        gateway.serverDate = now - 1.minutes
        engine.drain(pull = true)
        gateway.calls.clear()
        return listId.toString() to itemId.toString()
    }

    @Test
    fun thePullStoresThePeopleOfASharedListAndMyRole() =
        runBlocking {
            val (listId, _) = sharedList(ListRole.Editor)

            assertEquals(ListRole.Editor, db.lists().get(listId)?.role)
            val people = db.participants().get(listId)
            assertEquals(listOf(owner.toString(), me.toString()), people.map { it.userId })
            assertEquals(listOf("Hadrien", "Léa"), people.map { it.displayName })
            assertEquals(listOf(false, true), people.map { it.isMe })
            // Arrivée de la liste : pas un changement de rôle à annoncer.
            assertTrue(changes.isEmpty())
        }

    @Test
    fun aRoleLoweredByTheOwnerIsNoticedAtThePull() =
        runBlocking {
            val (listId, _) = sharedList(ListRole.Editor)
            gateway.listMembers = gateway.listMembers.map { it.copy(role = ListRole.Viewer) }

            engine.drain(pull = true)

            assertEquals(ListRole.Viewer, db.lists().get(listId)?.role)
            assertEquals(listOf(AccessChange.Downgraded(listId, "Hadrien", 0)), changes)

            gateway.listMembers = gateway.listMembers.map { it.copy(role = ListRole.Editor) }
            engine.drain(pull = true)
            assertEquals(AccessChange.Upgraded(listId, "Hadrien"), changes.last())
        }

    @Test
    fun aDowngradeSeenByTheSheetDropsTheEntriesAndIsNoticedOnce() =
        runBlocking {
            val (listId, itemId) = sharedList(ListRole.Editor)
            repository.setChecked(itemId, now, now)
            repository.addItem(listId, "beurre", "beurre", null, null, "dairy", now)
            gateway.roles[Uuid.parse(listId)] = ListRole.Viewer
            gateway.listMembers = gateway.listMembers.map { it.copy(role = ListRole.Viewer) }

            // La feuille « Partager » ouverte lit le nouveau rôle avant la descente.
            sharing.listSharing(listId)

            assertEquals(ListRole.Viewer, db.lists().get(listId)?.role)
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(listOf(itemId), db.items().getByList(listId).map { it.id })
            assertNull(db.items().get(itemId)?.checkedAt)
            assertEquals(listOf(AccessChange.Downgraded(listId, "Hadrien", 2)), changes)

            // La descente suivante voit le même rôle : pas de seconde bannière.
            engine.drain(pull = true)
            assertEquals(1, changes.size)
        }

    @Test
    fun aDowngradeSeenByTheSheetSurvivesANetworkCutWithASingleNotice() =
        runBlocking {
            val (listId, itemId) = sharedList(ListRole.Editor)
            repository.setChecked(itemId, now, now)
            gateway.roles[Uuid.parse(listId)] = ListRole.Viewer
            gateway.listMembers = gateway.listMembers.map { it.copy(role = ListRole.Viewer) }
            // La feuille lit l'abaissement, puis le réseau coupe pendant le rechargement de la liste.
            gateway.failNext("fetchItemsOfList", RemoteError.Network())

            assertEquals(InviteErrorKind.Offline, failure { sharing.listSharing(listId) })
            // Rien d'écrit à moitié : rôle, entrée et message attendent la lecture suivante.
            assertEquals(ListRole.Editor, db.lists().get(listId)?.role)
            assertEquals(1, db.outbox().all().size)
            assertTrue(changes.isEmpty())

            sharing.listSharing(listId)
            engine.drain(pull = true)
            assertEquals(ListRole.Viewer, db.lists().get(listId)?.role)
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(listOf(AccessChange.Downgraded(listId, "Hadrien", 1)), changes)
        }

    @Test
    fun anUnreadableItemEntryIsRejectedWithoutBlockingTheQueue() =
        runBlocking {
            val (listId, itemId) = sharedList(ListRole.Editor)
            repository.setChecked(itemId, now, now)
            val entry = db.outbox().all().single()
            db.outbox().setPayload(entry.id, "{".encodeToByteArray())
            repository.addItem(listId, "beurre", "beurre", null, null, "dairy", now)

            engine.drain()

            // Charge illisible : rejetée (« payload »), l'article suivant part quand même.
            assertTrue(gateway.callsOf("insertItem").isNotEmpty())
            val left = db.outbox().all()
            assertEquals(listOf(itemId), left.map { it.entityId })
            assertEquals(SyncState.FAILED, left.single().syncState)
        }

    @Test
    fun aSentItemIsReportedForItsList() =
        runBlocking {
            val (listId, itemId) = sharedList(ListRole.Editor)
            repository.setChecked(itemId, now, now)

            engine.drain()

            // Avant et après l'envoi : l'écho du signal `items` peut précéder la réponse.
            assertEquals(listOf(listId, listId), itemsSent)
        }

    @Test
    fun refreshAccessRemovesAListThatIsNoLongerShared() =
        runBlocking {
            val (listId, itemId) = sharedList()
            repository.setChecked(itemId, now, now)
            gateway.accessible = { emptyList() }

            engine.refreshAccess(listId)

            assertNull(db.lists().get(listId))
            assertNull(db.items().get(itemId))
            assertTrue(db.outbox().all().isEmpty())
            assertTrue(db.participants().get(listId).isEmpty())
            assertEquals(listOf(AccessChange.Removed(listId, "Courses de la semaine")), changes)
        }

    @Test
    fun refreshAccessAsViewerDropsTheEntriesOfTheList() =
        runBlocking {
            val (listId, itemId) = sharedList()
            repository.setChecked(itemId, now, now)
            repository.addItem(listId, "beurre", "beurre", null, null, "dairy", now)
            gateway.roles[Uuid.parse(listId)] = ListRole.Viewer

            engine.refreshAccess(listId)

            assertEquals(ListRole.Viewer, db.lists().get(listId)?.role)
            assertTrue(db.outbox().all().isEmpty())
            // Liste rechargée : l'article non envoyé disparaît, la coche aussi.
            assertEquals(listOf(itemId), db.items().getByList(listId).map { it.id })
            assertNull(db.items().get(itemId)?.checkedAt)
            assertEquals(listOf(AccessChange.Downgraded(listId, "Hadrien", 2)), changes)
        }

    @Test
    fun aRefusedUpdateOnASharedListEndsReadOnly() =
        runBlocking {
            val (listId, itemId) = sharedList()
            repository.setChecked(itemId, now, now)
            // L'éditeur est passé lecteur : la RLS filtre la mise à jour, sans pierre tombale.
            gateway.rowTouched = { false }
            gateway.roles[Uuid.parse(listId)] = ListRole.Viewer

            engine.drain()

            assertTrue(gateway.calls.contains("listSharing:$listId"))
            assertEquals(ListRole.Viewer, db.lists().get(listId)?.role)
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(listOf(AccessChange.Downgraded(listId, "Hadrien", 1)), changes)
        }

    @Test
    fun acceptingAnInvitationPullsTheListBeforeOpeningIt() =
        runBlocking {
            gateway.serverDate = now - 1.minutes
            engine.drain(pull = true)
            val listId = Uuid.random()
            val itemId = Uuid.random()
            gateway.remoteLists = listOf(ListRow(listId, owner, "Apéro", now, now))
            gateway.remoteItems = listOf(ListItemRow(itemId, listId, null, "chips", null, null, now, now, owner))
            gateway.listMembers = listOf(ListMemberRow(listId, me, ListRole.Editor, owner, now, now))
            gateway.acceptance = InvitationAcceptance("accepted", listId, ListRole.Editor)

            val result = sharing.acceptInvitation(Uuid.random())

            assertEquals(AcceptOutcome.Joined, SharingDecisions.acceptOutcome(result.status))
            assertEquals(listId, result.listId)
            assertEquals("chips", db.items().get(itemId.toString())?.label)
            assertEquals(ListRole.Editor, db.lists().get(listId.toString())?.role)
        }

    @Test
    fun anExpiredInvitationOpensNothing() =
        runBlocking {
            gateway.acceptance = InvitationAcceptance("expired")
            assertEquals("expired", sharing.acceptInvitation("t".repeat(43)).status)
            assertTrue(gateway.callsOf("fetchLists").isEmpty())
        }

    @Test
    fun sharingFailuresAreTranslatedForTheSheet() =
        runBlocking {
            val listId = Uuid.random().toString()
            gateway.failNext("sendInvitation", SharingRequestError("already_member"))
            assertEquals(
                InviteErrorKind.AlreadyMember,
                failure { sharing.sendInvitation(listId, "lea@x.fr", ListRole.Editor) },
            )

            gateway.failNext("sendInvitation", RemoteError.Network())
            assertEquals(
                InviteErrorKind.Offline,
                failure { sharing.sendInvitation(listId, "lea@x.fr", ListRole.Editor) },
            )

            gateway.failNext("sendInvitation", RemoteError.Forbidden())
            assertEquals(
                InviteErrorKind.NotAllowed,
                failure { sharing.sendInvitation(listId, "lea@x.fr", ListRole.Editor) },
            )

            // Hors ligne : rien ne part, rien n'est mis en file.
            online = false
            gateway.calls.clear()
            assertEquals(
                InviteErrorKind.Offline,
                failure { sharing.sendInvitation(listId, "lea@x.fr", ListRole.Editor) },
            )
            assertTrue(gateway.calls.isEmpty())
            assertTrue(db.outbox().all().isEmpty())
        }

    @Test
    fun leavingAListRemovesItFromTheDevice() =
        runBlocking {
            val (listId, itemId) = sharedList()
            repository.setChecked(itemId, now, now)

            sharing.leaveList(listId)

            assertEquals(listOf("removeMember:$me"), gateway.callsOf("removeMember"))
            assertNull(db.lists().get(listId))
            assertTrue(db.outbox().all().isEmpty())
            // Départ voulu : aucun message « n'est plus partagée ».
            assertTrue(changes.isEmpty())
        }

    @Test
    fun theSharingSheetUpdatesThePeopleOfTheList() =
        runBlocking {
            val (listId, _) = sharedList()
            val tom = Uuid.random()
            gateway.listMembers =
                gateway.listMembers + ListMemberRow(Uuid.parse(listId), tom, ListRole.Viewer, owner, now, now)
            gateway.profiles = gateway.profiles + ProfileRow(tom, "Tom", now, now)

            val result = sharing.listSharing(listId)

            assertEquals(listOf("Hadrien", "Léa", "Tom"), result.participants.map { it.displayName })
            assertNotNull(db.participants().get(listId).firstOrNull { it.displayName == "Tom" })
        }

    private suspend fun failure(block: suspend () -> Unit): InviteErrorKind {
        try {
            block()
        } catch (e: SharingFailure) {
            return e.kind
        }
        fail("aucun échec")
        error("inaccessible")
    }
}
