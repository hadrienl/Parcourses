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
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.designsystem.CapsText
import fr.parcourses.core.designsystem.OsmAttribution
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketSheet
import fr.parcourses.core.designsystem.TicketType

/** Politique de confidentialité publiée sur le site (#87, lot 87.8), la même pour tous les builds. */
const val PRIVACY_POLICY_URL = "https://parcourses.hadrien.eu/confidentialite/"

/**
 * « À propos » (iOS : `AboutView`, lot 9.12) : d'où viennent les magasins (OpenStreetMap, ODbL), ce que l'app
 * enregistre et pourquoi, la police embarquée et la version. Mêmes textes qu'iOS.
 *
 * La section « Session » n'apparaît que si la clé de session reste illisible (#51, Android seulement). La section
 * « Compte » (#87) montre l'adresse et le prénom, ou propose de se connecter. La section « Vos données » (#68), sous
 * « Confidentialité », propose de tout supprimer.
 *
 * Les textes sur les données suivent le type de compte (#87, lot 87.8, iOS : `isEmailAccount`) : identifiant anonyme,
 * ou compte e-mail (adresse et prénom), qui n'est jamais purgé pour inactivité.
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
    account: AccountUiState = AccountUiState(),
    accountActions: AccountActions = AccountActions(),
) {
    val colors = Ticket.colors
    val emailAccount = account.account.kind == AccountKind.Email
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
                    Section(stringResource(R.string.about_session_title)) {
                        SessionResetContent(sessionReset, sessionResetActions)
                    }
                }
                if (account.visible) {
                    Section(stringResource(R.string.account_title)) { AccountContent(account, accountActions) }
                }
                Section(stringResource(R.string.about_data_title)) {
                    Paragraph(stringResource(R.string.about_data_body))
                    OsmAttribution(textAlign = TextAlign.Start)
                }
                PrivacySection(emailAccount, localOnly = accountDeletion.localOnly)
                Section(stringResource(R.string.about_account_title)) {
                    AccountDeletionContent(accountDeletion, accountDeletionActions, emailAccount)
                }
                Section(stringResource(R.string.about_font_title)) {
                    Paragraph(stringResource(R.string.about_font_body))
                }
                Section(stringResource(R.string.about_version_title)) {
                    Paragraph(version)
                }
            }
        }
    }
}

/** « Confidentialité ». [localOnly] : build sans Supabase, rien ne part vers un serveur. */
@Composable
private fun PrivacySection(
    emailAccount: Boolean,
    localOnly: Boolean,
) {
    Section(stringResource(R.string.about_privacy_title)) {
        Paragraph(stringResource(R.string.about_privacy_tracking))
        Paragraph(stringResource(if (emailAccount) R.string.about_privacy_data_email else R.string.about_privacy_data))
        Paragraph(stringResource(R.string.about_privacy_catalog))
        Paragraph(stringResource(R.string.about_privacy_location))
        // Seulement avec un serveur : sans lui, rien n'en part.
        if (!localOnly) {
            val deletion = if (emailAccount) R.string.about_privacy_deletion_email else R.string.about_privacy_deletion
            Paragraph(stringResource(deletion))
        }
        // Même sans serveur : la politique décrit aussi ce qui reste sur l'appareil.
        PrivacyPolicyLink()
    }
}

@Composable
private fun Section(
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
private fun Paragraph(text: String) {
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
