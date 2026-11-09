package fr.parcourses.core.designsystem

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp

/** Page de licence demandée par l'ODbL. */
const val OSM_COPYRIGHT_URL = "https://www.openstreetmap.org/copyright"

/**
 * « © contributeurs OpenStreetMap, licence ODbL » partout où des magasins sont montrés (iOS : `OSMAttribution`). Toute
 * la ligne est une cible d'au moins 48 dp, annoncée « Ouvrir la page de licence d'OpenStreetMap » par TalkBack.
 */
@Composable
fun OsmAttribution(
    modifier: Modifier = Modifier,
    textAlign: TextAlign = TextAlign.Center,
) {
    val text = stringResource(R.string.osm_attribution)
    val uriHandler = LocalUriHandler.current
    Text(
        buildAnnotatedString { withLink(LinkAnnotation.Url(OSM_COPYRIGHT_URL)) { append(text) } },
        style = TicketType.meta.copy(textDecoration = TextDecoration.Underline),
        color = Ticket.colors.inkMuted,
        textAlign = textAlign,
        modifier =
            modifier
                .fillMaxWidth()
                .heightIn(min = TicketDimens.touchMin)
                .clickable(onClickLabel = stringResource(R.string.osm_attribution_action)) {
                    uriHandler.openUri(OSM_COPYRIGHT_URL)
                }.wrapContentHeight(Alignment.CenterVertically)
                .padding(horizontal = TicketDimens.spaceM, vertical = 4.dp),
    )
}
