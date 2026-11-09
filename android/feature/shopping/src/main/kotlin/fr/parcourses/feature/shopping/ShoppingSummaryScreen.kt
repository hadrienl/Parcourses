package fr.parcourses.feature.shopping

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import fr.parcourses.core.designsystem.DashedRule
import fr.parcourses.core.designsystem.OsmAttribution
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketSheet

/**
 * Écran de fin branché sur la navigation : la vibration de réussite (iOS : `sensoryFeedback(.success)`) ne part
 * qu'une fois, ni à la rotation ni au retour après la mort du processus (l'état est sauvegardé avec l'entrée).
 */
@Composable
fun ShoppingSummaryRoute(
    summary: ShoppingSummary,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    var celebrated by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (!celebrated) {
            celebrated = true
            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
        }
    }
    ShoppingSummaryScreen(summary, onClose, modifier)
}

/**
 * Fin des courses (#6, iOS `ShoppingSummaryView`) : « 12 articles en 18 min », puis la contribution en une phrase
 * sincère, dans un écran calme, sans badge ni série. « Retour aux listes » reste en bas, à portée du pouce.
 *
 * Accessibilité : l'écran se présente à TalkBack par son titre de volet (« Courses terminées »), sauf
 * [announcesPane] à `false` (repli affiché par le mode courses le temps de la navigation : l'entrée du résumé
 * s'annonce ensuite, une seule fois) ; le nombre d'articles et la durée forment un seul titre ; à 200 % le contenu
 * défile au-dessus du bouton, toujours visible.
 */
@Composable
fun ShoppingSummaryScreen(
    summary: ShoppingSummary,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    announcesPane: Boolean = true,
) {
    val pane = stringResource(R.string.shopping_summary_pane)
    val contribution = contributionText(summary)
    val colors = Ticket.colors
    Scaffold(
        modifier = if (announcesPane) modifier.semantics { paneTitle = pane } else modifier,
        containerColor = colors.desk,
        bottomBar = {
            Button(
                onClick = onClose,
                colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = 24.dp, vertical = 16.dp)
                        .heightIn(min = TicketDimens.primaryAction)
                        .testTag(TAG_CLOSE),
            ) { Text(stringResource(R.string.shopping_summary_close), textAlign = TextAlign.Center) }
        },
    ) { padding ->
        TicketSheet(Modifier.padding(padding)) {
            BoxWithConstraints(Modifier.fillMaxSize()) {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .heightIn(min = maxHeight)
                        .padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    SummaryHeadline(summary)
                    DashedRule()
                    contribution?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodyLarge,
                            color = colors.inkMuted,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.testTag(TAG_CONTRIBUTION),
                        )
                    }
                    if (summary.storeName != null) OsmAttribution()
                }
            }
        }
    }
}

/** Nombre d'articles et durée : un seul titre pour TalkBack (« 12 articles, en 18 min »). */
@Composable
private fun SummaryHeadline(summary: ShoppingSummary) {
    Column(
        Modifier.semantics(mergeDescendants = true) { heading() }.testTag(TAG_SUMMARY_HEADLINE),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            pluralStringResource(
                R.plurals.shopping_summary_articles,
                frenchQuantity(summary.checkedCount),
                summary.checkedCount,
            ),
            style = MaterialTheme.typography.displaySmall,
            color = Ticket.colors.ink,
            textAlign = TextAlign.Center,
            modifier = Modifier.testTag(TAG_SUMMARY),
        )
        Text(
            stringResource(R.string.shopping_summary_minutes, summary.minutes),
            style = MaterialTheme.typography.titleLarge,
            color = Ticket.colors.inkMuted,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * Ce que la visite apporte au magasin, d'après ce que l'app en savait pendant la visite (confiance de l'instantané,
 * `store_stats.confidence_q`). Rien sans magasin. Comme iOS, la phrase est dite même sans coche.
 */
@Composable
private fun contributionText(summary: ShoppingSummary): String? {
    val store = summary.storeName ?: return null
    return when (val knowledge = summary.knowledge) {
        RouteKnowledge.NoStore -> null
        RouteKnowledge.Unknown -> stringResource(R.string.shopping_summary_first, store)
        is RouteKnowledge.Learning -> stringResource(R.string.shopping_summary_known, store, knowledge.percent)
        is RouteKnowledge.Learned -> stringResource(R.string.shopping_summary_known, store, knowledge.percent)
    }
}

/**
 * Quantité à donner au pluriel pour suivre la règle française (0 et 1 au singulier, comme iOS : `count <= 1`) quelle
 * que soit la langue de l'appareil. Android choisit la règle d'après la langue de l'appareil, pas d'après celle des
 * textes, et un dossier `values-fr` ne serait même pas choisi sur un appareil en anglais : 0 y serait « other »
 * (« 0 articles »). 1 donne « one » en français comme en anglais ; 2 et plus, « other ».
 */
internal fun frenchQuantity(count: Int): Int = if (count <= 1) 1 else count
