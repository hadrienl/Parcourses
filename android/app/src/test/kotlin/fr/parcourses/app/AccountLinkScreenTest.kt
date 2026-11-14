package fr.parcourses.app

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountLinkError
import fr.parcourses.core.data.account.AccountLinkPhase
import fr.parcourses.core.data.account.AccountLinkState
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.core.network.dto.EmailCodePurpose
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/** « Se connecter » (#87) : saisie, code à 6 chiffres (validation au 6ᵉ, autofill), « Bon retour », TalkBack. */
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class AccountLinkScreenTest {
    @get:Rule
    val rule = createComposeRule()

    private val requested = mutableListOf<Pair<String, String?>>()
    private val verified = mutableListOf<String>()
    private var resent = 0
    private var changed = 0
    private var closed = 0

    private val actions =
        AccountLinkActions(
            onRequestCode = { email, name -> requested += email to name },
            onVerify = { verified += it },
            onResend = { resent++ },
            onChangeEmail = { changed++ },
        )

    private fun show(state: () -> AccountLinkUiState) {
        rule.setContent { ParcoursesTheme { AccountLinkScreen(state(), actions, onClose = { closed++ }) } }
    }

    @Test
    fun theCodeIsRequestedOnceTheAddressAndTheNameAreValid() {
        show { AccountLinkUiState(AccountLinkState()) }
        rule.onNodeWithText("Se connecter").assertExists()
        rule.onNodeWithTag(TAG_LINK_SEND).assertIsNotEnabled()
        rule.onNodeWithTag(TAG_LINK_EMAIL).performTextInput("lea@exemple.fr")
        rule.onNodeWithTag(TAG_LINK_SEND).assertIsNotEnabled()
        rule.onNodeWithTag(TAG_LINK_NAME).performTextInput("Léa")
        rule.onNodeWithTag(TAG_LINK_SEND).assertIsEnabled().performClick()
        assertEquals(listOf("lea@exemple.fr" to "Léa"), requested)
        rule.onNodeWithTag(TAG_LINK_EMAIL).assert(hasContentType(ContentType.EmailAddress))
    }

    @Test
    fun aReconnectionAsksOnlyForTheAddressAndShowsItsError() {
        show { AccountLinkUiState(AccountLinkState(asksDisplayName = false, error = AccountLinkError.RateLimited)) }
        rule.onNodeWithTag(TAG_LINK_NAME).assertDoesNotExist()
        rule.onNodeWithText("Trop de codes demandés. Réessayez dans 1 min.").assertExists()
        rule.onNodeWithTag(TAG_LINK_EMAIL).performTextInput("lea@exemple.fr")
        rule.onNodeWithTag(TAG_LINK_SEND).performClick()
        assertEquals(listOf("lea@exemple.fr" to null), requested)
    }

    @Test
    fun theSixthDigitVerifiesAndResendWaitsSixtySeconds() {
        var state by mutableStateOf(codeState(resendIn = 42))
        show { state }
        rule.onNodeWithText("Envoyé à lea@exemple.fr. Il expire dans 15 minutes.").assertExists()
        val field = rule.onNodeWithTag(TAG_CODE_FIELD)
        field.assert(hasContentType(ContentType.SmsOtpCode))
        field.assert(SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription, listOf("Code à 6 chiffres")))
        rule.onNodeWithText("Renvoyer le code dans 42 s").assertExists()
        rule.onNodeWithTag(TAG_CODE_RESEND).assertIsNotEnabled()

        field.performTextInput("12 34")
        assertEquals(emptyList<String>(), verified)
        field.performTextInput("56")
        assertEquals(listOf("123456"), verified)

        state = codeState(resendIn = 0, error = AccountLinkError.InvalidCode)
        rule.onNodeWithText("Ce code ne correspond pas. Vérifiez le dernier e-mail reçu.").assertExists()
        rule.onNodeWithTag(TAG_CODE_RESEND).assertIsEnabled().performClick()
        assertEquals(1, resent)
        rule.onNodeWithTag(TAG_CODE_CHANGE).performClick()
        assertEquals(1, changed)
    }

    @Test
    fun aSignInToAnExistingAccountWelcomesBack() {
        show {
            AccountLinkUiState(
                AccountLinkState(
                    phase = AccountLinkPhase.Done,
                    welcomeBack = true,
                    listsAdded = 2,
                    displayName = "Léa",
                ),
            )
        }
        rule.onNodeWithText("Bon retour, Léa !").assertExists()
        rule.onNodeWithText("Les 2 listes de ce téléphone ont été ajoutées à votre compte.").assertExists()
        rule.onNodeWithText("Voir mes listes").performClick()
        assertEquals(1, closed)
    }

    @Test
    fun theMergeCannotBeLeft() {
        show { AccountLinkUiState(AccountLinkState(phase = AccountLinkPhase.Merging)) }
        rule.onNodeWithText("Rapprochement de vos listes…").assertExists()
        rule.onNodeWithTag(TAG_LINK_CLOSE).assertDoesNotExist()
    }

    private fun codeState(
        resendIn: Int,
        error: AccountLinkError? = null,
    ) = AccountLinkUiState(
        AccountLinkState(
            phase = AccountLinkPhase.EnterCode,
            email = "lea@exemple.fr",
            purpose = EmailCodePurpose.Link,
            error = error,
        ),
        resendIn = resendIn,
    )

    private fun hasContentType(type: ContentType) = SemanticsMatcher.expectValue(SemanticsProperties.ContentType, type)
}
