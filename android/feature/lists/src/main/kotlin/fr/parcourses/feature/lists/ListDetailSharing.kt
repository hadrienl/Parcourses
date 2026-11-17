package fr.parcourses.feature.lists

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.KeyboardActionHandler
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.text
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import fr.parcourses.core.data.sharing.AccessChange
import fr.parcourses.core.designsystem.AisleLine
import fr.parcourses.core.designsystem.AvatarSize
import fr.parcourses.core.designsystem.Bead
import fr.parcourses.core.designsystem.DockPill
import fr.parcourses.core.designsystem.ItemLine
import fr.parcourses.core.designsystem.MemberAvatar
import fr.parcourses.core.designsystem.MemberStack
import fr.parcourses.core.designsystem.NoticeCard
import fr.parcourses.core.designsystem.RowLane
import fr.parcourses.core.designsystem.SharingBadge
import fr.parcourses.core.designsystem.ThreadBead
import fr.parcourses.core.designsystem.ThreadGutter
import fr.parcourses.core.designsystem.ThreadLayout
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketCheckBox
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketHeader
import fr.parcourses.core.designsystem.TicketSheet
import fr.parcourses.core.designsystem.TicketType
import fr.parcourses.core.designsystem.dockFieldColors
import fr.parcourses.core.designsystem.dockFieldTextStyle
import fr.parcourses.core.designsystem.isLargeText
import fr.parcourses.core.designsystem.laneIndication
import fr.parcourses.core.model.ListRole
import kotlinx.coroutines.launch
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

// Écran Liste, partie partage (#87, lot 87.6) : barre, bandeaux, lignes d'un lecteur, liste retirée.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DetailTopBar(
    state: ListDetailUiState,
    onBack: () -> Unit,
    onShare: (() -> Unit)?,
) {
    val sharing = state.sharing
    val readOnlyTitle =
        stringResource(R.string.ro_title_a11y, state.name, ownerName(sharing.ownerName))
    TopAppBar(
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Ticket.colors.desk),
        title = {
            Text(
                state.name,
                modifier =
                    if (sharing.role == ListRole.Viewer) {
                        Modifier.semantics { contentDescription = readOnlyTitle }
                    } else {
                        Modifier
                    },
            )
        },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.detail_back),
                )
            }
        },
        actions = { if (onShare != null) MembersButton(sharing, onShare) },
    )
}

/** Badge de lecture seule, accès abaissé, hors ligne : au-dessus des articles. */
@Composable
internal fun SharingBanners(
    sharing: ListSharingUi,
    onAcknowledge: (AccessChange) -> Unit,
) {
    if (sharing.role == ListRole.Viewer) ReadOnlyBadge()
    (sharing.notice as? AccessChange.Downgraded)?.let { notice -> DowngradeBanner(notice) { onAcknowledge(notice) } }
    if (sharing.isOffline) OfflineBanner(stringResource(R.string.sharing_offline))
}

/** « Beurre doux, 1, dernière modification par Léa » : l'auteur passe dans le libellé, la marque est décorative. */
@Composable
internal fun spokenLabel(row: ItemRow): String =
    row.authorMark?.let {
        row.accessibilityLabel + ", " + stringResource(R.string.detail_item_by_a11y, memberName(row.authorName))
    } ?: row.accessibilityLabel

/** Initiale du dernier auteur, après la quantité : avatar de 20 dp au trait, non tactile. */
@Composable
internal fun AuthorMark(mark: String?) {
    if (mark == null) return
    MemberAvatar(
        mark,
        size = AvatarSize.mark,
        outlined = true,
        modifier = Modifier.padding(start = TicketDimens.spaceXs).testTag(TAG_AUTHOR),
    )
}

/**
 * Ligne d'un lecteur (§7) : ni case ni corbeille. Un article coché est barré avec une coche ; un appui rappelle
 * seulement que la liste ne se modifie pas ici. Pas de rôle « case à cocher » pour TalkBack.
 */
@Composable
internal fun ReadOnlyItemRow(
    row: ItemRow,
    bead: Bead,
    onTap: () -> Unit,
) {
    val colors = Ticket.colors
    val basket = stringResource(R.string.ro_item_in_basket)
    val label = spokenLabel(row).let { if (row.isChecked) "$it, $basket" else it }
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                // L'ondulation est dans le couloir, jamais sur la gouttière (#115).
                .clickable(interactionSource = interaction, indication = null, onClick = onTap)
                .clearAndSetSemantics { contentDescription = label }
                .padding(start = ThreadLayout.start),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ThreadGutter(row.id) { ThreadBead(bead) }
        RowLane {
            Row(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .laneIndication(interaction)
                        .heightIn(min = TicketDimens.rowMin)
                        .padding(start = TicketDimens.spaceXs, end = TicketDimens.spaceM),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(TicketDimens.checkBox), contentAlignment = Alignment.Center) {
                    if (row.isChecked) Icon(Icons.Default.Check, contentDescription = null, tint = colors.checked)
                }
                ItemLine(
                    name = row.label,
                    quantity = row.quantity,
                    style = TicketType.item,
                    color = if (row.isChecked) colors.checked else colors.ink,
                    decoration = if (row.isChecked) TextDecoration.LineThrough else null,
                    modifier = Modifier.weight(1f).padding(start = TicketDimens.spaceS, top = 6.dp, bottom = 6.dp),
                )
                AuthorMark(row.authorMark)
            }
        }
    }
}

/** La liste n'est plus partagée avec moi : état plein écran, focus sur le titre, retour à « Mes listes ». */
@Composable
internal fun RemovedState(
    notice: AccessChange.Removed,
    onBack: () -> Unit,
) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(notice) { runCatching { focus.requestFocus() } }
    Column(
        Modifier.fillMaxSize().padding(32.dp).testTag(TAG_REMOVED),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Outlined.Lock,
            contentDescription = null,
            tint = Ticket.colors.inkMuted,
            modifier = Modifier.size(56.dp).border(2.dp, Ticket.colors.inkMuted, CircleShape).padding(14.dp),
        )
        Text(
            stringResource(R.string.sharing_removed_title, notice.listName),
            style = MaterialTheme.typography.headlineSmall,
            color = Ticket.colors.ink,
            textAlign = TextAlign.Center,
            // Focusable : sans cible de focus, la demande échoue et TalkBack ne va pas au titre.
            modifier = Modifier.semantics { heading() }.focusRequester(focus).focusable(),
        )
        Text(
            stringResource(R.string.sharing_removed_body),
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.inkMuted,
            textAlign = TextAlign.Center,
        )
        Button(
            onClick = onBack,
            colors =
                ButtonDefaults.buttonColors(
                    containerColor = Ticket.colors.accent,
                    contentColor = Ticket.colors.onAccent,
                ),
            modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.primaryAction).testTag(TAG_REMOVED_BACK),
        ) { Text(stringResource(R.string.sharing_removed_back)) }
    }
}
