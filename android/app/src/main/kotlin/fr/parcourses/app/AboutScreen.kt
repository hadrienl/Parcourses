package fr.parcourses.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import fr.parcourses.core.designsystem.CapsText
import fr.parcourses.core.designsystem.OsmAttribution
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketSheet
import fr.parcourses.core.designsystem.TicketType

/**
 * « À propos » (iOS : `AboutView`, lot 9.12) : d'où viennent les magasins (OpenStreetMap, ODbL), ce que l'app
 * enregistre et pourquoi, la police embarquée et la version. Mêmes textes qu'iOS.
 *
 * La section « Session » n'apparaît que si la clé de session reste illisible (#51, Android seulement). La section
 * « Vos données » (#68), sous « Confidentialité », propose de tout supprimer.
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
                    Section(stringResource(R.string.about_session_title)) {
                        SessionResetContent(sessionReset, sessionResetActions)
                    }
                }
                Section(stringResource(R.string.about_data_title)) {
                    Paragraph(stringResource(R.string.about_data_body))
                    OsmAttribution(textAlign = TextAlign.Start)
                }
                Section(stringResource(R.string.about_privacy_title)) {
                    Paragraph(stringResource(R.string.about_privacy_tracking))
                    Paragraph(stringResource(R.string.about_privacy_data))
                    Paragraph(stringResource(R.string.about_privacy_location))
                    // Seulement avec un serveur : sans lui, rien n'en part.
                    if (!accountDeletion.localOnly) Paragraph(stringResource(R.string.about_privacy_deletion))
                }
                Section(stringResource(R.string.about_account_title)) {
                    AccountDeletionContent(accountDeletion, accountDeletionActions)
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
