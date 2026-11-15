package fr.parcourses.feature.lists

import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.sharing.AccessChange
import fr.parcourses.core.data.sharing.InvitationCardState
import fr.parcourses.core.data.sharing.InviteErrorKind
import fr.parcourses.core.database.entity.ListParticipantEntity
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.dto.InvitationAcceptance
import fr.parcourses.core.network.dto.InvitationPreview
import fr.parcourses.core.network.dto.ReceivedInvitation
import fr.parcourses.core.network.dto.SentInvitation
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.uuid.Uuid

/** Modèles du partage (#87, lot 87.6) : feuille « Partager », invitations, partage vu de l'écran Liste. */
@RunWith(AndroidJUnit4::class)
class SharingViewModelsTest : ListsTest() {
    private val service = FakeSharingService()

    private fun shareModel(reloads: MutableSharedFlow<Set<String>> = MutableSharedFlow()) =
        tracked {
            ShareListViewModel(
                listId = service.listId.toString(),
                service = service,
                listName = flowOf("Courses de la semaine"),
                reloads = reloads,
            )
        }

    // region Feuille « Partager »

    @Test
    fun theSheetLoadsMembersAndPendingInvitations() {
        val model = shareModel()
        val state = model.uiState.await { it.load == ShareLoad.Loaded }
        assertTrue(state.isOwner)
        assertEquals(listOf("Hadrien", "Léa"), state.members.map { it.displayName })
        assertEquals(listOf("c.martin@exemple.fr"), state.invitations.map { it.email })
        assertEquals("Courses de la semaine", state.listName)
        assertEquals(ListRole.Editor, state.role)
    }

    @Test
    fun anInvalidAddressNeverLeavesTheDevice() {
        val model = shareModel()
        model.uiState.await { it.load == ShareLoad.Loaded }
        model.email.setTextAndPlaceCursorAtEnd("lea@exemple")
        model.send()
        assertEquals(InviteErrorKind.InvalidEmail, model.uiState.value.emailError)
        assertTrue(service.calls.none { it.startsWith("send") })
    }

    @Test
    fun sendingInvitesWithTheChosenRoleAndClearsTheField() {
        val model = shareModel()
        model.uiState.await { it.load == ShareLoad.Loaded }
        model.selectRole(ListRole.Viewer)
        model.email.setTextAndPlaceCursorAtEnd("  Zoe@Exemple.fr ")
        model.send()
        val state = model.uiState.await { it.message != null }
        assertEquals(ShareMessage.Sent("zoe@exemple.fr"), state.message)
        assertTrue(service.calls.contains("send:zoe@exemple.fr:viewer"))
        assertEquals("", model.email.text.toString())
        assertFalse(state.isSending)
    }

    @Test
    fun aServerRefusalStaysOnTheField() {
        val model = shareModel()
        model.uiState.await { it.load == ShareLoad.Loaded }
        service.failure = InviteErrorKind.AlreadyMember
        model.email.setTextAndPlaceCursorAtEnd("lea@exemple.fr")
        model.send()
        val state = model.uiState.await { it.emailError != null }
        assertEquals(InviteErrorKind.AlreadyMember, state.emailError)
        assertEquals("lea@exemple.fr", state.refusedEmail)
        // Le champ garde l'adresse ; la retaper efface l'erreur.
        assertEquals("lea@exemple.fr", model.email.text.toString())
        model.emailEdited()
        assertNull(model.uiState.value.emailError)
    }

    @Test
    fun anEmailThatDidNotLeaveOffersTheLink() {
        service.sent = SentInvitation(Uuid.random(), "parcourses://invitation#abc", sent = false, service.now)
        val model = shareModel()
        model.uiState.await { it.load == ShareLoad.Loaded }
        model.email.setTextAndPlaceCursorAtEnd("zoe@exemple.fr")
        model.send()
        assertEquals("parcourses://invitation#abc", model.uiState.await { it.mailFailLink != null }.mailFailLink)
        model.copyMailFailLink()
        val state = model.uiState.value
        assertEquals("parcourses://invitation#abc", state.clip)
        assertEquals(ShareMessage.Copied(fresh = false), state.message)
    }

    @Test
    fun copyingAPendingLinkMakesANewToken() {
        val model = shareModel()
        val invitation =
            model.uiState
                .await { it.load == ShareLoad.Loaded }
                .invitations
                .single()
        model.copyLink(invitation)
        val state = model.uiState.await { it.clip != null }
        assertEquals("parcourses://invitation#fresh", state.clip)
        assertEquals(ShareMessage.Copied(fresh = true), state.message)
        model.clipConsumed()
        assertNull(model.uiState.value.clip)
    }

    @Test
    fun changingAnAccessIsConfirmedAndOfflineIsSaid() {
        val model = shareModel()
        val lea =
            model.uiState
                .await { it.load == ShareLoad.Loaded }
                .members
                .last()
        model.setRole(lea, ListRole.Viewer)
        assertEquals(
            ShareMessage.RoleChanged("Léa", ListRole.Viewer),
            model.uiState.await { it.message != null }.message,
        )
        assertTrue(service.calls.contains("role:${lea.userId}:viewer"))
        model.messageShown()

        service.failure = InviteErrorKind.Offline
        model.remove(lea)
        assertEquals(ShareMessage.MemberOffline, model.uiState.await { it.message != null }.message)
        assertNull(model.uiState.await { it.busyId == null }.busyId)
    }

    @Test
    fun aMemberSeesTheMembersSheetAndCanLeave() {
        service.sharing = service.sharing.copy(role = ListRole.Editor, invitations = emptyList())
        val model = shareModel()
        assertFalse(model.uiState.await { it.load == ShareLoad.Loaded }.isOwner)
        model.leave()
        assertTrue(model.uiState.await { it.left }.left)
        assertTrue(service.calls.contains("leave:${service.listId}"))
    }

    @Test
    fun theSheetCannotOpenOffline() {
        service.failure = InviteErrorKind.Offline
        val model = shareModel()
        assertEquals(ShareLoad.Offline, model.uiState.await { it.load != ShareLoad.Loading }.load)
        model.retry()
        assertEquals(ShareLoad.Loaded, model.uiState.await { it.load == ShareLoad.Loaded }.load)
    }

    @Test
    fun aSignalReloadsTheOpenSheet() =
        runBlocking {
            val reloads = MutableSharedFlow<Set<String>>(extraBufferCapacity = 1)
            val model = shareModel(reloads)
            model.uiState.await { it.load == ShareLoad.Loaded }
            val before = service.calls.count { it == "listSharing" }
            service.sharing = service.sharing.copy(invitations = emptyList())
            reloads.emit(setOf(service.listId.toString()))
            assertTrue(
                model.uiState
                    .await { it.invitations.isEmpty() }
                    .invitations
                    .isEmpty(),
            )
            assertEquals(before + 1, service.calls.count { it == "listSharing" })
        }

    // endregion

    // region Invitations

    private val invitation =
        ReceivedInvitation(
            Uuid.random(),
            Uuid.random(),
            "Courses de la semaine",
            "Hadrien",
            ListRole.Editor,
            service.now,
        )

    @Test
    fun invitationsAreReadForAnEmailAccountOnly() {
        service.received = listOf(invitation)
        val email = MutableStateFlow(false)
        val model = tracked { InvitationsViewModel(service, email) }
        assertTrue(
            model.uiState.value.invitations
                .isEmpty(),
        )
        assertTrue(service.calls.isEmpty())
        email.value = true
        assertEquals(listOf(invitation), model.uiState.await { it.invitations.isNotEmpty() }.invitations)
    }

    @Test
    fun acceptingOpensTheList() {
        service.received = listOf(invitation)
        service.acceptance = InvitationAcceptance("accepted", invitation.listId, ListRole.Editor)
        val model = tracked { InvitationsViewModel(service, flowOf(true)) }
        model.uiState.await { it.invitations.isNotEmpty() }
        model.accept(invitation)
        val state = model.uiState.await { it.openList != null }
        assertEquals(invitation.listId.toString(), state.openList)
        assertTrue(state.invitations.isEmpty())
        model.listOpened()
        assertNull(model.uiState.value.openList)
    }

    @Test
    fun anAcceptanceErrorStaysUnderTheCard() {
        service.received = listOf(invitation)
        val model = tracked { InvitationsViewModel(service, flowOf(true)) }
        model.uiState.await { it.invitations.isNotEmpty() }
        service.failure = InviteErrorKind.Offline
        model.accept(invitation)
        val state = model.uiState.await { it.error != null }
        assertEquals(invitation.id.toString() to InvitationError.Offline, state.error)
        assertEquals(listOf(invitation), state.invitations)
        assertNull(state.accepting)
    }

    @Test
    fun decliningRemovesTheCard() {
        service.received = listOf(invitation)
        val model = tracked { InvitationsViewModel(service, flowOf(true)) }
        model.uiState.await { it.invitations.isNotEmpty() }
        model.decline(invitation)
        assertTrue(
            model.uiState
                .await { it.invitations.isEmpty() }
                .invitations
                .isEmpty(),
        )
        assertTrue(service.calls.contains("decline:${invitation.id}"))
    }

    @Test
    fun aLinkForAnotherAddressWarnsFirst() {
        service.preview =
            InvitationPreview(
                status = "pending",
                inviterName = "Hadrien",
                role = ListRole.Editor,
                emailMatches = false,
                invitedEmailMasked = "c•••@exemple.fr",
            )
        val model = tracked { InvitationLinkViewModel("t".repeat(43), service) { "tom@exemple.fr" } }
        val state = model.uiState.await { !it.loading }
        assertEquals(InvitationCardState.OtherAddress, state.card)
        assertEquals("tom@exemple.fr", state.accountEmail)
        model.accept()
        assertEquals(service.listId.toString(), model.uiState.await { it.openList != null }.openList)
    }

    @Test
    fun anExpiredLinkSaysSo() {
        service.preview = InvitationPreview(status = "expired", inviterName = "Hadrien")
        val model = tracked { InvitationLinkViewModel("t".repeat(43), service) }
        assertEquals(InvitationCardState.Expired, model.uiState.await { !it.loading }.card)
        assertTrue(service.calls.none { it.startsWith("accept") })
    }

    @Test
    fun aLinkWithoutTokenIsInvalid() {
        val model = tracked { InvitationLinkViewModel(null, service) }
        val state = model.uiState.value
        assertTrue(state.missing)
        assertEquals(InvitationCardState.Invalid, state.card)
    }

    // endregion

    // region Écran Liste

    private fun sharedDetail(
        listId: String,
        role: ListRole,
        online: Boolean = true,
        notices: List<AccessChange> = emptyList(),
    ): ListDetailViewModel {
        runBlocking {
            db.lists().setRole(listId, role)
            db.participants().upsertAll(
                listOf(
                    ListParticipantEntity(listId, OWNER, "Hadrien", ListRole.Owner, isMe = false),
                    ListParticipantEntity(listId, ME, "Léa", role, isMe = true),
                ),
            )
        }
        return tracked {
            ListDetailViewModel(
                listId = listId,
                lists = lists,
                products =
                    fr.parcourses.core.data.repository
                        .RoomProductRepository(db),
                categories =
                    fr.parcourses.core.data.repository
                        .RoomCategoryRepository(db),
                analyzer = analyzer,
                now = { clock },
                computation = kotlinx.coroutines.Dispatchers.Unconfined,
                sharingSources =
                    ListSharingSources(
                        participants = { db.participants().observe(it) },
                        isOnline = flowOf(online),
                        notices = flowOf(notices),
                    ),
            )
        }
    }

    @Test
    fun anItemChangedByAnotherMemberCarriesTheirInitial() {
        val list = runBlocking { lists.createList("Courses", clock) }
        val item = runBlocking { lists.addItem(list.id, "beurre", "beurre", "1", null, "dairy", clock) }
        runBlocking { db.items().upsert(checkNotNull(db.items().get(item.id)).copy(updatedBy = OWNER)) }
        val model = sharedDetail(list.id, ListRole.Editor)
        val state = model.uiState.await { it.sections.isNotEmpty() && it.sharing.isShared }
        val row =
            state.sections
                .single()
                .items
                .single()
        assertEquals("H", row.authorMark)
        assertEquals("Hadrien", row.authorName)
        assertEquals("Hadrien", state.sharing.lastChange?.authorName)
        assertEquals(listOf("H"), state.sharing.others.map { it.label })
        assertTrue(state.sharing.capabilities.canEditItems)
        assertFalse(state.sharing.capabilities.canShare)
    }

    @Test
    fun aViewerReadsOnlyAndSeesTheOfflineBanner() {
        val list = runBlocking { lists.createList("Courses", clock) }
        val model = sharedDetail(list.id, ListRole.Viewer, online = false)
        val state = model.uiState.await { it.sharing.isShared }
        assertFalse(state.sharing.capabilities.canEditItems)
        assertFalse(state.sharing.capabilities.canShop)
        assertTrue(state.sharing.isOffline)
        assertEquals("Hadrien", state.sharing.ownerName)
    }

    @Test
    fun theAccessNoticeOfTheListIsShown() {
        val list = runBlocking { lists.createList("Courses", clock) }
        val notice = AccessChange.Downgraded(list.id, "Hadrien", 2)
        val model =
            sharedDetail(list.id, ListRole.Viewer, notices = listOf(AccessChange.Removed("autre", "Autre"), notice))
        assertEquals(
            notice,
            model.uiState
                .await { it.sharing.notice != null }
                .sharing.notice,
        )
    }

    // endregion

    private companion object {
        const val OWNER = "22222222-2222-4222-8222-222222222222"
        const val ME = "11111111-1111-4111-8111-111111111111"
    }
}
