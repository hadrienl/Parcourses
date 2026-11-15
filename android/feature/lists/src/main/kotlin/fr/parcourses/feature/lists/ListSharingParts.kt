package fr.parcourses.feature.lists

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import fr.parcourses.core.data.sharing.AccessChange
import fr.parcourses.core.designsystem.MemberStack
import fr.parcourses.core.designsystem.NoticeCard
import fr.parcourses.core.designsystem.SharingBadge
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketType
import kotlinx.coroutines.delay
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

// Partage vu de l'écran Liste (#87, lot 87.6, maquettes §1 et §7).

/** Prénoms joints à la française : « Léa », « Léa et Tom », « Léa, Tom et Zoé ». */
@Composable
internal fun joinedNames(names: List<String>): String =
    when (names.size) {
        0 -> ""
        1 -> names[0]
        else -> stringResource(R.string.sharing_and, names.dropLast(1).joinToString(", "), names.last())
    }

/** Prénom affiché d'un membre ; sans prénom, « Un autre membre ». */
@Composable
internal fun memberName(name: String?): String = name?.takeIf { it.isNotBlank() } ?: stringResource(R.string.sharing_someone)

/** Prénom du propriétaire ; sans prénom, « Le propriétaire ». */
@Composable
internal fun ownerName(name: String?): String =
    name?.takeIf { it.isNotBlank() } ?: stringResource(R.string.sharing_owner_fallback)

/** « il y a 2 min » à l'écran, « il y a 2 minutes » pour TalkBack. */
internal data class Ago(
    val short: String,
    val spoken: String,
)

@Composable
internal fun ago(
    at: Instant,
    now: Instant,
): Ago {
    val elapsed = (now - at).coerceAtLeast(Duration.ZERO)
    return when {
        elapsed < 1.minutes -> {
            val n = elapsed.inWholeSeconds.toInt()
            Ago(stringResource(R.string.ago_seconds, n), pluralStringResource(R.plurals.ago_seconds_a11y, n, n))
        }

        elapsed < 1.hours -> {
            val n = elapsed.inWholeMinutes.toInt()
            Ago(stringResource(R.string.ago_minutes, n), pluralStringResource(R.plurals.ago_minutes_a11y, n, n))
        }

        elapsed < 1.days -> {
            val n = elapsed.inWholeHours.toInt()
            Ago(stringResource(R.string.ago_hours, n), pluralStringResource(R.plurals.ago_hours_a11y, n, n))
        }

        else -> {
            val n = elapsed.inWholeDays.toInt()
            Ago(stringResource(R.string.ago_days, n), pluralStringResource(R.plurals.ago_days_a11y, n, n))
        }
    }
}

/** L'heure qui avance pour « il y a… » : une mise à jour toutes les 30 s suffit. */
@Composable
internal fun rememberNow(clock: () -> Instant = { Clock.System.now() }): Instant {
    var now by remember { mutableStateOf(clock()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(TICK)
            now = clock()
        }
    }
    return now
}

private val TICK = 30.seconds

/**
 * Bouton des membres dans la barre de la liste : les pastilles des autres membres, ou l'icône « Partager » tant que la
 * liste n'est qu'à moi. Propriétaire : ouvre « Partager la liste » ; membre : « Membres ». Cible de 48 dp.
 */
@Composable
internal fun MembersButton(
    sharing: ListSharingUi,
    onClick: () -> Unit,
) {
    if (!sharing.isShared) {
        if (!sharing.capabilities.canShare) return
        IconButton(onClick = onClick, modifier = Modifier.testTag(TAG_SHARE)) {
            Icon(Icons.Default.Share, contentDescription = stringResource(R.string.detail_share))
        }
        return
    }
    val names = joinedNames(sharing.others.map { memberName(it.name) })
    val label =
        if (sharing.capabilities.canShare) {
            stringResource(R.string.detail_members_share_a11y, names)
        } else {
            stringResource(R.string.detail_members_view_a11y, names)
        }
    Row(
        Modifier
            .heightIn(min = TicketDimens.touchMin)
            .sizeIn(minWidth = TicketDimens.touchMin)
            .clip48()
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) {
                role = Role.Button
                contentDescription = label
            }.padding(horizontal = 10.dp)
            .testTag(TAG_SHARE),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MemberStack(sharing.others.map { it.label })
    }
}

private fun Modifier.clip48(): Modifier = this.then(Modifier.heightIn(min = TicketDimens.touchMin))

/** « Modifiée par Léa · il y a 2 min » sous le compteur, en deux lignes si le texte est agrandi. */
@Composable
internal fun LastChangeLine(
    change: LastChange,
    modifier: Modifier = Modifier,
) {
    val now = rememberNow()
    val name = memberName(change.authorName)
    val ago = ago(change.at, now)
    val spoken = stringResource(R.string.detail_last_change_a11y, name, ago.spoken)
    Text(
        stringResource(R.string.detail_last_change, name, ago.short),
        style = TicketType.meta,
        color = Ticket.colors.inkMuted,
        modifier =
            modifier
                .fillMaxWidth()
                .padding(horizontal = TicketDimens.spaceM)
                .clearAndSetSemantics { contentDescription = spoken }
                .testTag(TAG_LAST_CHANGE),
    )
}

/** Bandeau hors ligne d'une liste partagée : non interactif, 44 dp au moins, ne recouvre pas le dock. */
@Composable
internal fun OfflineBanner(
    text: String,
    modifier: Modifier = Modifier,
) {
    NoticeCard(
        modifier
            .fillMaxWidth()
            .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs)
            .testTag(TAG_OFFLINE),
        caution = false,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Info, contentDescription = null, tint = Ticket.colors.ink)
            Text(
                text,
                style = MaterialTheme.typography.bodyMedium,
                color = Ticket.colors.ink,
                modifier = Modifier.padding(start = TicketDimens.spaceXs).semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
    }
}

/** Accès abaissé : bannière d'avertissement annoncée tout de suite, avec « Compris ». */
@Composable
internal fun DowngradeBanner(
    notice: AccessChange.Downgraded,
    onAcknowledge: () -> Unit,
) {
    val owner = ownerName(notice.ownerName)
    val text =
        if (notice.lostChanges > 0) {
            pluralStringResource(R.plurals.sharing_downgrade, notice.lostChanges, owner, notice.lostChanges)
        } else {
            stringResource(R.string.sharing_downgrade_plain, owner)
        }
    NoticeCard(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs)
            .testTag(TAG_DOWNGRADE),
    ) {
        Column {
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Outlined.Warning, contentDescription = null, tint = Ticket.colors.caution)
                Text(
                    text,
                    style = MaterialTheme.typography.bodyMedium,
                    color = Ticket.colors.ink,
                    modifier =
                        Modifier
                            .padding(start = TicketDimens.spaceXs)
                            .semantics { liveRegion = LiveRegionMode.Assertive },
                )
            }
            TextButton(
                onClick = onAcknowledge,
                modifier = Modifier.align(Alignment.End).heightIn(min = TicketDimens.touchMin),
            ) { Text(stringResource(R.string.sharing_understood), color = Ticket.colors.accent) }
        }
    }
}

/** Badge « LECTURE SEULE » sous la barre, sur sa propre ligne. */
@Composable
internal fun ReadOnlyBadge(modifier: Modifier = Modifier) {
    SharingBadge(
        stringResource(R.string.ro_badge),
        readOnly = true,
        modifier = modifier.padding(horizontal = TicketDimens.spaceM, vertical = 4.dp).testTag(TAG_READ_ONLY_BADGE),
    )
}

/**
 * Note du bas pour un lecteur, à la place du dock : texte statique (pas un bouton désactivé), lu en dernier, 56 dp de
 * haut au moins. Elle grandit avec le texte, la liste défile au-dessus.
 */
@Composable
internal fun ReadOnlyNote(
    ownerName: String?,
    modifier: Modifier = Modifier,
) {
    val colors = Ticket.colors
    val text =
        ownerName?.takeIf { it.isNotBlank() }?.let { stringResource(R.string.ro_notice, it) }
            ?: stringResource(R.string.ro_tap)
    Row(
        modifier
            .fillMaxWidth()
            .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs)
            .heightIn(min = TicketDimens.primaryAction)
            .border(1.dp, colors.paperEdge, RoundedCornerShape(TicketDimens.radius + 8.dp))
            .padding(TicketDimens.spaceS)
            .testTag(TAG_READ_ONLY_NOTE),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.Lock, contentDescription = null, tint = colors.ink)
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = colors.ink,
            modifier = Modifier.padding(start = TicketDimens.spaceS),
        )
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
            modifier = Modifier.focusRequester(focus).semantics { heading() },
        )
        Text(
            stringResource(R.string.sharing_removed_body),
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.inkMuted,
            textAlign = TextAlign.Center,
        )
        Button(
            onClick = onBack,
            colors = ButtonDefaults.buttonColors(containerColor = Ticket.colors.accent, contentColor = Ticket.colors.onAccent),
            modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.primaryAction).testTag(TAG_REMOVED_BACK),
        ) { Text(stringResource(R.string.sharing_removed_back)) }
    }
}

internal const val TAG_SHARE = "detail-share"
internal const val TAG_LAST_CHANGE = "detail-last-change"
internal const val TAG_OFFLINE = "detail-offline"
internal const val TAG_DOWNGRADE = "detail-downgrade"
internal const val TAG_READ_ONLY_BADGE = "detail-read-only"
internal const val TAG_READ_ONLY_NOTE = "detail-read-only-note"
internal const val TAG_REMOVED = "detail-removed"
internal const val TAG_REMOVED_BACK = "detail-removed-back"
internal const val TAG_AUTHOR = "detail-author"
