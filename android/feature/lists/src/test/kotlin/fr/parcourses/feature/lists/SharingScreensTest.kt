package fr.parcourses.feature.lists

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.sharing.AccessChange
import fr.parcourses.core.data.sharing.InviteErrorKind
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.dto.ReceivedInvitation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.uuid.Uuid

/** Écrans du partage (#87, lot 87.6) : feuille « Partager », carte d'invitation, lecture seule. */
@RunWith(AndroidJUnit4::class)
class SharingScreensTest {
    @get:Rule
    val rule = createComposeRule()

    private val service = FakeSharingService()
    private val calls = mutableListOf<String>()

    private fun showShare(state: ShareListUiState) {
        rule.setContent {
            ParcoursesTheme {
                ShareListScreen(
                    state = state,
                    email = TextFieldState(),
                    actions =
                        ShareListActions(
                            onSend = { calls += "send" },
                            onRole = { calls += "role:${it.wireName}" },
                            onSetRole = { member, role -> calls += "set:${member.displayName}:${role.wireName}" },
                            onLeave = { calls += "leave" },
                        ),
                )
            }
        }
    }

    private val loaded =
        ShareListUiState(listName = "Courses de la semaine", load = ShareLoad.Loaded, sharing = service.sharing)

    @Test
    fun theOwnerSheetOffersTheFormMembersAndPendingInvitations() {
        showShare(loaded)
        rule.onNodeWithText("Partager la liste").assertIsDisplayed()
        rule.onNodeWithText("«\u00A0Courses de la semaine\u00A0»").assertExists()
        rule.onNodeWithTag(TAG_SHARE_EMAIL).assertExists()
        rule.onNodeWithText("Peut modifier").assertExists()
        rule.onNodeWithText("Lecture seule").performClick()
        rule.onNodeWithTag(TAG_SHARE_SEND).performClick()
        assertEquals(listOf("role:viewer", "send"), calls)
        // Une invitation en attente se lit d'un bloc : adresse, accès, échéance.
        val pending = hasContentDescription("c.martin@exemple.fr", substring = true)
        rule.onNodeWithTag(TAG_SHARE_LIST).performScrollToNode(pending)
        rule.onNode(pending).assertExists()
        rule.onNode(hasContentDescription("Hadrien (vous), propriétaire")).assertExists()
    }

    @Test
    fun theOwnerManagesAMemberFromItsSheet() {
        showShare(loaded)
        val lea = service.sharing.members.single()
        rule.onNodeWithTag(TAG_SHARE_LIST).performScrollToNode(hasContentDescription("Léa, peut modifier. Gérer"))
        rule.onNodeWithContentDescription("Léa, peut modifier. Gérer").performClick()
        rule.onNodeWithTag(TAG_MEMBER_SHEET).assertExists()
        rule.onNodeWithTag("$TAG_MEMBER_ROLE-viewer").performClick()
        assertEquals(listOf("set:Léa:viewer"), calls)
        assertEquals(ListRole.Editor, lea.role)
    }

    @Test
    fun aRefusedAddressIsShownUnderTheField() {
        showShare(loaded.copy(emailError = InviteErrorKind.AlreadyMember, refusedEmail = "lea@exemple.fr"))
        rule.onNodeWithText("lea@exemple.fr fait déjà partie de la liste.").assertExists()
    }

    @Test
    fun aMemberSeesTheMembersAndCanLeaveAfterConfirming() {
        showShare(loaded.copy(sharing = service.sharing.copy(role = ListRole.Editor, invitations = emptyList())))
        rule.onNodeWithText("Membres").assertIsDisplayed()
        rule.onAllNodesWithTag(TAG_SHARE_EMAIL).assertCountEquals(0)
        rule.onNodeWithTag(TAG_SHARE_LIST).performScrollToNode(hasText("Quitter la liste"))
        rule.onNodeWithTag(TAG_SHARE_LEAVE).performClick()
        rule.onNodeWithTag(TAG_CONFIRM_SHARING).performClick()
        assertEquals(listOf("leave"), calls)
    }

    @Test
    fun offlineTheSheetOffersToRetry() {
        showShare(ShareListUiState(load = ShareLoad.Offline))
        rule.onNodeWithText("Le partage demande une connexion.").assertExists()
        rule.onNodeWithTag(TAG_SHARE_RETRY).assertExists()
    }

    @Test
    fun theInvitationCardAcceptsAndConfirmsTheRefusal() {
        val invitation =
            ReceivedInvitation(
                Uuid.random(),
                Uuid.random(),
                "Courses de la semaine",
                "Hadrien",
                ListRole.Editor,
                service.now,
            )
        rule.setContent {
            ParcoursesTheme {
                InvitationsEntry(
                    InvitationsUiState(invitations = listOf(invitation)),
                    onAccept = { calls += "accept" },
                    onDecline = { calls += "decline" },
                    onOpenAll = { calls += "all" },
                )
            }
        }
        rule.onNodeWithTag(TAG_INVITATION_CARD).assertExists()
        rule
            .onNodeWithText("Hadrien vous invite à «\u00A0Courses de la semaine\u00A0»", useUnmergedTree = true)
            .assertExists()
        rule.onNodeWithTag(TAG_INVITATION_ACCEPT).performClick()
        rule.onNodeWithTag(TAG_INVITATION_DECLINE).performClick()
        rule.onNodeWithText("Refuser l’invitation\u202F?").assertExists()
        rule.onNodeWithTag(TAG_CONFIRM_SHARING).performClick()
        assertEquals(listOf("accept", "decline"), calls)
    }

    @Test
    fun severalInvitationsShowAsOneEntry() {
        val first = ReceivedInvitation(Uuid.random(), Uuid.random(), "A", "Hadrien", ListRole.Editor, service.now)
        val second = first.copy(id = Uuid.random(), listName = "B", inviterName = "Camille")
        rule.setContent {
            ParcoursesTheme {
                InvitationsEntry(InvitationsUiState(invitations = listOf(first, second)), {}, {}, { calls += "all" })
            }
        }
        rule.onNodeWithText("Invitations (2)").assertExists()
        rule.onNodeWithText("Hadrien et Camille").assertExists()
        rule.onNodeWithTag(TAG_INVITATIONS_ROW).performClick()
        assertEquals(listOf("all"), calls)
    }

    @Test
    fun aViewerCannotCheckNorAddNorShop() {
        val milk = ItemRow("1", "Lait entier", "2", "dairy", "lait entier", isChecked = false)
        val cheese =
            ItemRow("2", "Comté", "200 g", "dairy", "comte", isChecked = true, authorMark = "L", authorName = "Léa")
        val toggled = mutableListOf<String>()
        rule.setContent {
            ParcoursesTheme {
                ListDetailScreen(
                    state =
                        ListDetailUiState(
                            name = "Courses de la semaine",
                            sections = listOf(ItemSection("dairy", "Crèmerie", listOf(milk, cheese))),
                            isLoaded = true,
                            sharing =
                                ListSharingUi(
                                    role = ListRole.Viewer,
                                    others = listOf(MemberChip("o", "H", "Hadrien", ListRole.Owner)),
                                    ownerName = "Hadrien",
                                ),
                        ),
                    input = TextFieldState(),
                    onSubmit = {},
                    onSuggestion = {},
                    onToggle = { toggled += it.id },
                    onDelete = {},
                    onBack = {},
                    onDismissError = {},
                    onStartShopping = { calls += "shop" },
                    onShare = { calls += "members" },
                )
            }
        }
        rule.onNodeWithTag(TAG_READ_ONLY_BADGE).assertExists()
        rule.onNodeWithTag(TAG_READ_ONLY_NOTE).assertExists()
        rule.onNodeWithText("Lecture seule. Demandez à Hadrien l’accès en modification.").assertExists()
        rule.onAllNodesWithTag(TAG_QUICK_ENTRY).assertCountEquals(0)
        rule.onAllNodesWithTag(TAG_SHOP).assertCountEquals(0)
        rule.onNodeWithContentDescription("Comté, 200 g, dernière modification par Léa, dans le panier").assertExists()
        rule.onNodeWithContentDescription("Lait entier, 2").performClick()
        rule.onNodeWithText("Lecture seule\u00A0: cette liste ne se modifie pas ici.").assertExists()
        assertTrue(toggled.isEmpty())
        rule.onNodeWithContentDescription("Membres\u00A0: Hadrien et vous. Voir les membres").performClick()
        assertEquals(listOf("members"), calls)
    }

    @Test
    fun aListNoLongerSharedShowsItsMessage() {
        var backs = 0
        val removed = AccessChange.Removed("l", "Courses de la semaine")
        rule.setContent {
            ParcoursesTheme {
                ListDetailScreen(
                    state =
                        ListDetailUiState(
                            isLoaded = true,
                            isMissing = true,
                            sharing = ListSharingUi(notice = removed),
                        ),
                    input = TextFieldState(),
                    onSubmit = {},
                    onSuggestion = {},
                    onToggle = {},
                    onDelete = {},
                    onBack = { backs++ },
                    onDismissError = {},
                    onAcknowledge = { calls += "ack" },
                )
            }
        }
        rule.onNodeWithText("«\u00A0Courses de la semaine\u00A0» n’est plus partagée avec vous").assertExists()
        rule.onNodeWithTag(TAG_REMOVED_BACK).performClick()
        assertEquals(1, backs)
        assertEquals(listOf("ack"), calls)
    }
}
