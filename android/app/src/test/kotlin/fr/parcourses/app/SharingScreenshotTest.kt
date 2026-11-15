package fr.parcourses.app

import android.app.Application
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.RoborazziOptions
import com.github.takahirom.roborazzi.captureRoboImage
import fr.parcourses.core.data.repository.ListSummary
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.dto.InvitationPreview
import fr.parcourses.core.network.dto.ListParticipant
import fr.parcourses.core.network.dto.ListSharing
import fr.parcourses.core.network.dto.PendingInvitation
import fr.parcourses.core.network.dto.ReceivedInvitation
import fr.parcourses.feature.lists.InvitationLinkScreen
import fr.parcourses.feature.lists.InvitationLinkUiState
import fr.parcourses.feature.lists.InvitationsUiState
import fr.parcourses.feature.lists.ItemRow
import fr.parcourses.feature.lists.ItemSection
import fr.parcourses.feature.lists.LastChange
import fr.parcourses.feature.lists.ListDetailScreen
import fr.parcourses.feature.lists.ListDetailUiState
import fr.parcourses.feature.lists.ListSharingUi
import fr.parcourses.feature.lists.ListsInvitationsUi
import fr.parcourses.feature.lists.ListsScreen
import fr.parcourses.feature.lists.ListsUiState
import fr.parcourses.feature.lists.LocalSharingClock
import fr.parcourses.feature.lists.MemberChip
import fr.parcourses.feature.lists.ShareListActions
import fr.parcourses.feature.lists.ShareListScreen
import fr.parcourses.feature.lists.ShareListUiState
import fr.parcourses.feature.lists.ShareLoad
import fr.parcourses.core.data.sharing.InvitationCardState
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * Captures du partage (#87, lot 87.6, maquettes `design/sharing-v1.html`) : clair, sombre, police à 200 %. Heure fixe
 * ([LocalSharingClock]) : « il y a 2 min » ne dépend pas du jour où la CI tourne. Mêmes tâches que [ScreenshotTest].
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w411dp-h891dp-xxhdpi", application = Application::class)
class SharingScreenshotTest {
    @get:Rule
    val rule = createComposeRule()

    private val now = Instant.parse("2026-11-14T18:42:00Z")

    private fun capture(
        name: String,
        dark: Boolean = false,
        fontScale: Float = 1f,
        content: @Composable () -> Unit,
    ) {
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density.density, fontScale),
                LocalSharingClock provides { now },
            ) {
                ParcoursesTheme(darkTheme = dark) { content() }
            }
        }
        rule.mainClock.advanceTimeBy(SETTLE_MS)
        rule.onRoot().captureRoboImage("src/test/screenshots/$name.png", roborazziOptions = options)
    }

    // region Données

    private val lea = Uuid.parse("22222222-2222-4222-8222-222222222222")
    private val tom = Uuid.parse("44444444-4444-4444-8444-444444444444")
    private val me = Uuid.parse("11111111-1111-4111-8111-111111111111")

    private fun item(
        id: String,
        label: String,
        quantity: String?,
        category: String,
        checked: Boolean = false,
        by: String? = null,
    ) = ItemRow(id, label, quantity, category, label.lowercase(), checked, authorMark = by?.take(1), authorName = by)

    private val sections =
        listOf(
            ItemSection(
                "produce",
                "Fruits et légumes",
                listOf(item("1", "Tomates", "6", "produce"), item("2", "Basilic", "1", "produce")),
            ),
            ItemSection(
                "dairy",
                "Crèmerie, œufs, ultra-frais",
                listOf(
                    item("3", "Lait entier", "2", "dairy"),
                    item("4", "Beurre doux", "1", "dairy", by = "Léa"),
                    item("5", "Comté", "200 g", "dairy", checked = true),
                ),
            ),
            ItemSection("savory-grocery", "Épicerie salée", listOf(item("6", "Pâtes", "1", "savory-grocery"))),
        )

    private val others =
        listOf(
            MemberChip(lea.toString(), "L", "Léa", ListRole.Editor),
            MemberChip(tom.toString(), "T", "Tom", ListRole.Viewer),
        )

    private val shared =
        ListDetailUiState(
            name = "Courses de la semaine",
            sections = sections,
            isLoaded = true,
            sharing = ListSharingUi(others = others, ownerName = null, lastChange = LastChange("Léa", now - 2.minutes)),
        )

    private val readOnly =
        shared.copy(
            sharing =
                ListSharingUi(
                    role = ListRole.Viewer,
                    others =
                        listOf(
                            MemberChip(me.toString(), "H", "Hadrien", ListRole.Owner),
                            MemberChip(tom.toString(), "T", "Tom", ListRole.Viewer),
                        ),
                    ownerName = "Hadrien",
                    lastChange = LastChange("Léa", now - 2.minutes),
                ),
        )

    private val sharing =
        ListSharing(
            listId = Uuid.random(),
            role = ListRole.Owner,
            owner = ListParticipant(me, "Hadrien", isMe = true),
            members =
                listOf(
                    ListParticipant(lea, "Léa", ListRole.Editor, joinedAt = now - 2.days),
                    ListParticipant(tom, "Tom", ListRole.Viewer, joinedAt = now - 1.days),
                ),
            invitations =
                listOf(
                    PendingInvitation(Uuid.random(), "c.martin@exemple.fr", ListRole.Editor, now, now + 7.days),
                    PendingInvitation(Uuid.random(), "zoe@exemple.fr", ListRole.Viewer, now - 8.days, now - 1.days, 1, true),
                ),
        )

    private val share =
        ShareListUiState(listName = "Courses de la semaine", load = ShareLoad.Loaded, sharing = sharing)

    private val invitation =
        ReceivedInvitation(Uuid.random(), Uuid.random(), "Courses de la semaine", "Hadrien", ListRole.Editor, now + 7.days)

    private val lists =
        ListsUiState(
            lists =
                listOf(
                    ListSummary("1", "Courses de la semaine", 7, 9, ListRole.Owner, listOf("Léa", "Tom")),
                    ListSummary("2", "Apéro samedi", 0, 4, ListRole.Viewer, listOf("Camille")),
                    ListSummary("3", "Bricolage", 0, 0),
                ),
            isLoaded = true,
        )

    // endregion

    @Composable
    private fun Shared(state: ListDetailUiState = shared) =
        ListDetailScreen(state, TextFieldState(), {}, {}, {}, {}, {}, {}, onStartShopping = {}, onShare = {})

    @Test
    fun sharedListLight() = capture("sharing-list-light") { Shared() }

    @Test
    fun sharedListDark() = capture("sharing-list-dark", dark = true) { Shared() }

    @Test
    fun sharedListLarge() = capture("sharing-list-200", fontScale = 2f) { Shared() }

    @Test
    fun sharedListOffline() = capture("sharing-list-offline") { Shared(shared.copy(sharing = shared.sharing.copy(isOffline = true))) }

    @Test
    fun readOnlyLight() = capture("sharing-read-only-light") { Shared(readOnly) }

    @Test
    fun readOnlyDark() = capture("sharing-read-only-dark", dark = true) { Shared(readOnly) }

    @Test
    fun readOnlyLarge() = capture("sharing-read-only-200", fontScale = 2f) { Shared(readOnly) }

    @Composable
    private fun Share(state: ShareListUiState = share) = ShareListScreen(state, TextFieldState(), ShareListActions())

    @Test
    fun shareLight() = capture("sharing-share-light") { Share() }

    @Test
    fun shareDark() = capture("sharing-share-dark", dark = true) { Share() }

    @Test
    fun shareLarge() = capture("sharing-share-200", fontScale = 2f) { Share() }

    @Test
    fun shareMembers() = capture("sharing-members-dark", dark = true) { Share(share.copy(sharing = sharing.copy(role = ListRole.Editor, invitations = emptyList()))) }

    @Composable
    private fun ListsWithInvitation() =
        ListsScreen(
            lists,
            {},
            {},
            { _, _ -> },
            {},
            {},
            invitations = ListsInvitationsUi(state = InvitationsUiState(invitations = listOf(invitation))),
        )

    @Test
    fun invitationLight() = capture("sharing-invitation-light") { ListsWithInvitation() }

    @Test
    fun invitationDark() = capture("sharing-invitation-dark", dark = true) { ListsWithInvitation() }

    @Test
    fun invitationLarge() = capture("sharing-invitation-200", fontScale = 2f) { ListsWithInvitation() }

    @Test
    fun invitationOtherAddress() =
        capture("sharing-invitation-other-light") {
            InvitationLinkScreen(
                InvitationLinkUiState(
                    loading = false,
                    preview =
                        InvitationPreview(
                            status = "pending",
                            inviterName = "Hadrien",
                            role = ListRole.Editor,
                            emailMatches = false,
                            invitedEmailMasked = "c•••@exemple.fr",
                            expiresAt = now + 7.days,
                        ),
                    card = InvitationCardState.OtherAddress,
                    accountEmail = "tom@exemple.fr",
                ),
                {},
                {},
                {},
                {},
            )
        }

    private val options = RoborazziOptions(compareOptions = RoborazziOptions.CompareOptions(changeThreshold = 0.01f))

    private companion object {
        const val SETTLE_MS = 1_000L
    }
}
