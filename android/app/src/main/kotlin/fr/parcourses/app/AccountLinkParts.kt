package fr.parcourses.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.data.account.AccountLink
import fr.parcourses.core.data.account.AccountLinkError
import fr.parcourses.core.data.account.AccountLinkPhase
import fr.parcourses.core.data.account.AccountLinkState
import fr.parcourses.core.designsystem.MonoFamily
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketSheet
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

/**
 * Un seul champ (autofill `SmsOtpCode`, collage accepté) affiché en 6 cases décoratives : TalkBack l'annonce comme
 * « Code à 6 chiffres », avec les chiffres saisis.
 */
@Composable
internal fun CodeField(
    value: String,
    error: Boolean,
    enabled: Boolean,
    onValueChange: (String) -> Unit,
) {
    val label = stringResource(R.string.code_a11y)
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        enabled = enabled,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
        textStyle = TextStyle(color = Color.Transparent),
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp)
                .semantics {
                    contentDescription = label
                    contentType = ContentType.SmsOtpCode
                    if (error) error(label)
                }.testTag(TAG_CODE_FIELD),
        decorationBox = { inner ->
            Box(contentAlignment = Alignment.Center) {
                CodeCells(value, error)
                // Le champ réel reste dessous : curseur, collage et autofill.
                Box(Modifier.size(size = 1.dp)) { inner() }
            }
        },
    )
}

/** Les 6 cases, décoratives : le champ réel les recouvre. */
@Composable
private fun CodeCells(
    value: String,
    error: Boolean,
) {
    val colors = Ticket.colors
    Row(
        horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs, Alignment.CenterHorizontally),
        modifier = Modifier.fillMaxWidth(),
    ) {
        repeat(AccountLink.CODE_LENGTH) { index ->
            val digit = value.getOrNull(index)?.toString().orEmpty()
            val focused = index == value.length
            val border =
                when {
                    error -> MaterialTheme.colorScheme.error
                    focused -> colors.accent
                    else -> colors.paperEdge
                }
            Box(
                contentAlignment = Alignment.Center,
                modifier =
                    Modifier
                        .weight(1f)
                        .widthIn(max = 48.dp)
                        .heightIn(min = 56.dp)
                        .border(
                            if (focused) 2.dp else 1.dp,
                            border,
                            RoundedCornerShape(TicketDimens.radius),
                        ),
            ) {
                Text(
                    digit,
                    style = TextStyle(fontFamily = MonoFamily, fontSize = 24.sp),
                    color = colors.ink,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

/** Prénom d'un nouveau compte (Q3) : « Entre 1 et 40 caractères, sans adresse ni lien. » */
@Composable
internal fun DisplayNameField(
    name: String,
    valid: Boolean,
    onChange: (String) -> Unit,
    onSend: () -> Unit,
) {
    val wrong = name.isNotEmpty() && !valid
    OutlinedTextField(
        value = name,
        onValueChange = onChange,
        label = { Text(stringResource(R.string.link_name_label)) },
        singleLine = true,
        isError = wrong,
        supportingText = { Text(stringResource(if (wrong) R.string.link_name_error else R.string.link_name_help)) },
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { onSend() }),
        modifier =
            Modifier
                .fillMaxWidth()
                .semantics { contentType = ContentType.PersonFirstName }
                .testTag(TAG_LINK_NAME),
    )
}

@Composable
internal fun PrimaryButton(
    text: String,
    enabled: Boolean,
    busy: Boolean,
    onClick: () -> Unit,
    tag: String,
) {
    val colors = Ticket.colors
    Button(
        onClick = onClick,
        enabled = enabled,
        colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.primaryAction).testTag(tag),
    ) {
        if (busy) {
            CircularProgressIndicator(
                modifier = Modifier.size(size = 18.dp),
                color = colors.onAccent,
                strokeWidth = 2.dp,
            )
            Spacer(Modifier.size(size = TicketDimens.spaceXs))
        }
        Text(text)
    }
}

@Composable
internal fun ErrorMessage(text: String) {
    Text(
        text,
        color = MaterialTheme.colorScheme.error,
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive }.testTag(TAG_LINK_ERROR),
    )
}

@Composable
internal fun requestErrorText(error: AccountLinkError): String =
    stringResource(
        when (error) {
            AccountLinkError.InvalidEmail -> R.string.link_error_invalid_email
            AccountLinkError.RateLimited -> R.string.link_error_rate_limited
            AccountLinkError.Offline -> R.string.link_error_offline
            AccountLinkError.InvalidCode -> R.string.link_error_invalid_code
            AccountLinkError.ExpiredCode -> R.string.link_error_expired_code
            AccountLinkError.Unknown -> R.string.link_error_unknown
        },
    )

@Composable
internal fun codeErrorText(error: AccountLinkError): String =
    if (error ==
        AccountLinkError.RateLimited
    ) {
        stringResource(R.string.link_error_too_many_codes)
    } else {
        requestErrorText(error)
    }
