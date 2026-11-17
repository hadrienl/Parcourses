package fr.parcourses.app

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import fr.parcourses.core.designsystem.CapsText
import fr.parcourses.core.designsystem.OsmAttribution
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketSheet
import fr.parcourses.core.designsystem.TicketType

/** Politique de confidentialité publiée sur le site (#87, lot 87.8), la même pour tous les builds. */
const val PRIVACY_POLICY_URL = "https://parcourses.hadrien.eu/confidentialite/"

/**
 * Demande écrite de suppression d'un compte e-mail (#122) : même adresse et même objet que `/supprimer-mes-donnees/`
 * (iOS : `PrivacyLinks.deletionRequest`).
 */
const val DELETION_REQUEST_URI = "mailto:parcourses@hadrien.eu?subject=Supprimer%20mes%20donn%C3%A9es"

/** Objet de la demande, aussi passé à part : toutes les messageries ne lisent pas celui de l'adresse `mailto:`. */
const val DELETION_REQUEST_SUBJECT = "Supprimer mes données"

/**
 * « À propos » (iOS : `AboutView`, lot 9.12) : d'où viennent les magasins (OpenStreetMap, ODbL), ce que l'app
 * enregistre et pourquoi, la police embarquée et la version. Mêmes textes qu'iOS.
 *
 * La section « Session » n'apparaît que si la clé de session reste illisible (#51, Android seulement). Le compte a son
 * écran (#108, [AccountScreen]) : la section « Vos données » (#68), sous « Confidentialité », ne reste ici que pour un
 * compte anonyme, qui n'a pas d'écran Compte ; [isEmailAccount] la retire.
 *
 * Les textes sur les données suivent le type de compte (#87, lot 87.8, iOS : `isEmailAccount`) : identifiant anonyme,
 * ou compte e-mail (adresse et prénom), purgé après 3 ans sans utilisation, pas 365 jours. Le lien vers la politique
 * de confidentialité est là pour tous, avec ou sans serveur.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AboutScreen(
    version: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    sessionReset: SessionResetUiState = SessionResetUiState(),
    sessionResetActions: SessionResetActions = SessionResetActions(),
    accountDeletion: AccountDeletionUiState = AccountDeletionUiState(),
    accountDeletionActions: AccountDeletionActions = AccountDeletionActions(),
    isEmailAccount: Boolean = false,
) {
    val colors = Ticket.colors
    Scaffold(
        modifier = modifier,
        containerColor = colors.desk,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.desk),
                title = { Text(stringResource(R.string.about_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.about_back),
                        )
                    }
                },
            )
        },
    ) { padding ->
        TicketSheet(Modifier.padding(padding)) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = TicketDimens.spaceM),
                verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
            ) {
                if (sessionReset.visible) {
                    InfoSection(stringResource(R.string.about_session_title)) {
                        SessionResetContent(sessionReset, sessionResetActions, isEmailAccount)
                    }
                }
                InfoSection(stringResource(R.string.about_data_title)) {
                    InfoParagraph(stringResource(R.string.about_data_body))
                    OsmAttribution(textAlign = TextAlign.Start)
                }
                PrivacySection(localOnly = accountDeletion.localOnly, isEmailAccount = isEmailAccount)
                if (!isEmailAccount) {
                    InfoSection(stringResource(R.string.about_account_title)) {
                        AccountDeletionContent(accountDeletion, accountDeletionActions)
                    }
                }
                InfoSection(stringResource(R.string.about_font_title)) {
                    InfoParagraph(stringResource(R.string.about_font_body))
                }
                InfoSection(stringResource(R.string.about_version_title)) {
                    InfoParagraph(version)
                }
            }
        }
    }
}

/** Ce que l'app enregistre et pourquoi. Avec un serveur, où supprimer ces données : ci-dessous, ou l'écran Compte. */
@Composable
private fun PrivacySection(
    localOnly: Boolean,
    isEmailAccount: Boolean,
) {
    InfoSection(stringResource(R.string.about_privacy_title)) {
        InfoParagraph(stringResource(R.string.about_privacy_tracking))
        // Compte e-mail : les données sont rattachées au compte, plus à un identifiant anonyme (texte iOS).
        InfoParagraph(
            stringResource(if (isEmailAccount) R.string.about_privacy_data_email else R.string.about_privacy_data),
        )
        InfoParagraph(stringResource(R.string.about_privacy_catalog))
        InfoParagraph(stringResource(R.string.about_privacy_location))
        // Seulement avec un serveur : sans lui, rien n'en part. Compte e-mail : la suppression est dans l'écran Compte,
        // pas « ci-dessous », et la purge d'inactivité est à 3 ans, pas à 365 jours (#118, #122).
        if (!localOnly) {
            val deletion =
                if (isEmailAccount) {
                    R.string.about_privacy_deletion_account
                } else {
                    R.string.about_privacy_deletion
                }
            InfoParagraph(stringResource(deletion))
        }
        // Même sans serveur : la politique décrit aussi ce qui reste sur l'appareil.
        PrivacyPolicyLink()
    }
}

/** Section d'un écran d'information (À propos, Compte) : titre lu comme un titre, puis son contenu. */
@Composable
internal fun InfoSection(
    title: String,
    content: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs)) {
        CapsText(
            title,
            style = TicketType.aisle,
            color = Ticket.colors.inkMuted,
            heading = true,
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(
                        horizontal = TicketDimens.spaceM,
                    ).padding(top = TicketDimens.spaceS),
        )
        content()
    }
}

@Composable
internal fun InfoParagraph(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = Ticket.colors.ink,
        modifier = Modifier.fillMaxWidth().padding(horizontal = TicketDimens.spaceM, vertical = 2.dp),
    )
}

/**
 * « Politique de confidentialité », ouverte dans le navigateur. Toute la ligne est une cible d'au moins 48 dp, annoncée
 * « Ouvrir la politique de confidentialité dans le navigateur » par TalkBack.
 */
@Composable
private fun PrivacyPolicyLink() {
    val uriHandler = LocalUriHandler.current
    Text(
        buildAnnotatedString {
            withLink(LinkAnnotation.Url(PRIVACY_POLICY_URL)) { append(stringResource(R.string.about_privacy_policy)) }
        },
        style = MaterialTheme.typography.bodyMedium.copy(textDecoration = TextDecoration.Underline),
        color = Ticket.colors.ink,
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = TicketDimens.touchMin)
                .clickable(onClickLabel = stringResource(R.string.about_privacy_policy_action)) {
                    uriHandler.openUri(PRIVACY_POLICY_URL)
                }.wrapContentHeight(Alignment.CenterVertically)
                .padding(horizontal = TicketDimens.spaceM, vertical = 2.dp)
                .testTag(TAG_PRIVACY_POLICY),
    )
}

internal const val TAG_PRIVACY_POLICY = "about-privacy-policy"
