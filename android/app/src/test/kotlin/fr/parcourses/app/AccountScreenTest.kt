package fr.parcourses.app

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountState
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.designsystem.ParcoursesTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * Écran Compte (#108) et À propos sans section Compte : adresse, prénom, déconnexion et suppression sont dans Compte ;
 * À propos ne garde « Vos données » que pour un compte anonyme. Libellés lus et cibles tactiles.
 */
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class AccountScreenTest {
    @get:Rule
    val rule = createComposeRule()

    private val app = RuntimeEnvironment.getApplication()
    private val text = { id: Int -> app.getString(id) }

    private val email =
        AccountUiState(account = AccountState(AccountKind.Email, email = "hadrien@exemple.fr", displayName = "Hadrien"))

    @Test
    fun theAccountScreenShowsTheAddressTheNameSignOutAndDeletion() {
        val calls = mutableListOf<String>()
        rule.setContent {
            ParcoursesTheme {
                AccountScreen(
                    account = email,
                    accountActions =
                        AccountActions(
                            onSignOutRequest = { calls += "signOut" },
                            onEditName = { calls += "name" },
                        ),
                    onBack = { calls += "back" },
                    accountDeletionActions = AccountDeletionActions(onRequest = { calls += "delete" }),
                )
            }
        }
        rule.onNodeWithText(text(R.string.account_title)).assertExists()
        // Libellé et valeur en une seule annonce, sur une ligne de 56 dp.
        rule
            .onNodeWithTag(TAG_ACCOUNT_EMAIL)
            .assert(hasText(text(R.string.account_email)))
            .assert(hasText("hadrien@exemple.fr"))
            .assertHeightIsAtLeast(56.dp)
        rule
            .onNodeWithTag(TAG_ACCOUNT_NAME)
            .assert(hasText("Hadrien"))
            .assertHasClickAction()
            .assertHeightIsAtLeast(56.dp)
            .performClick()
        rule.onNodeWithText(text(R.string.account_note)).assertExists()
        rule.onNodeWithTag(TAG_ACCOUNT_SIGN_OUT).assertHeightIsAtLeast(48.dp).performClick()
        // « Vos données », lu comme un titre, puis « Supprimer mes données… ».
        rule
            .onNodeWithText(text(R.string.about_account_title))
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
        rule
            .onNodeWithTag(TAG_ACCOUNT_DELETE)
            .performScrollTo()
            .assert(hasText(text(R.string.about_account_action)))
            .assertHeightIsAtLeast(48.dp)
            .performClick()
        rule
            .onNodeWithTag(TAG_ACCOUNT_BACK)
            .assert(hasContentDescription(text(R.string.account_back)))
            .performClick()
        assertEquals(listOf("name", "signOut", "delete", "back"), calls)
        // Pas de reconnexion tant que la session est là.
        rule.onNodeWithTag(TAG_ACCOUNT_SESSION_LOST).assertDoesNotExist()
    }

    @Test
    fun aLostSessionOffersToReconnectAtTheTopInsteadOfSigningOut() {
        var signIns = 0
        rule.setContent {
            ParcoursesTheme {
                AccountScreen(
                    account = email.copy(account = email.account.copy(needsSignIn = true)),
                    accountActions = AccountActions(onSignIn = { signIns++ }),
                    onBack = {},
                )
            }
        }
        rule
            .onNodeWithText(text(R.string.account_session_lost))
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        rule.onNodeWithTag(TAG_ACCOUNT_RECONNECT).assertHeightIsAtLeast(48.dp).performClick()
        assertEquals(1, signIns)
        // Session perdue : pas de déconnexion ici, on se reconnecte ou on continue sans compte depuis les listes.
        rule.onNodeWithTag(TAG_ACCOUNT_SIGN_OUT).assertDoesNotExist()
    }

    @Test
    fun aSignOutInProgressDisablesTheButtonAndTheDialogsAskFirst() {
        var state by mutableStateOf(email.copy(signingOut = true))
        rule.setContent { ParcoursesTheme { AccountScreen(account = state, accountActions = AccountActions(), {}) } }
        rule.onNodeWithTag(TAG_ACCOUNT_SIGN_OUT).assertIsNotEnabled()

        state = email.copy(confirmingSignOut = true, unsentChanges = 2)
        rule.onNodeWithText(text(R.string.account_sign_out_title)).assertExists()
        rule.onNodeWithText(text(R.string.account_sign_out_unsent)).assertExists()
        rule.onNodeWithTag(TAG_ACCOUNT_SIGN_OUT_CONFIRM).assertExists()

        state = email.copy(editingName = true)
        rule.onNodeWithTag(TAG_ACCOUNT_NAME_FIELD).assertExists()
        rule.onNodeWithTag(TAG_ACCOUNT_NAME_SAVE).assertExists()
    }

    @Test
    fun withoutAFirstNameTheRowOffersToAddOne() {
        rule.setContent {
            ParcoursesTheme {
                AccountScreen(
                    account = email.copy(account = email.account.copy(displayName = null)),
                    accountActions = AccountActions(),
                    onBack = {},
                )
            }
        }
        rule.onNodeWithTag(TAG_ACCOUNT_NAME).assert(hasText(text(R.string.account_name_missing)))
    }

    @Test
    fun aboutNoLongerHasAnAccountSection() {
        rule.setContent { ParcoursesTheme { AboutScreen("1.0 (1)", {}, isEmailAccount = true) } }
        rule.onNodeWithText(text(R.string.account_title)).assertDoesNotExist()
        rule.onNodeWithTag(TAG_ACCOUNT_SIGN_OUT).assertDoesNotExist()
        rule.onNodeWithTag(TAG_ACCOUNT_NAME).assertDoesNotExist()
        // Compte e-mail : la suppression est dans l'écran Compte, pas « ci-dessous ».
        rule.onNodeWithTag(TAG_ACCOUNT_DELETE).assertDoesNotExist()
        rule.onNodeWithText(text(R.string.about_account_title)).assertDoesNotExist()
        rule.onNodeWithText(text(R.string.about_privacy_deletion_account)).assertExists()
        rule.onNodeWithText(text(R.string.about_privacy_deletion)).assertDoesNotExist()
    }

    @Test
    fun anAnonymousAccountKeepsItsDataSectionInAbout() {
        var deletions = 0
        rule.setContent {
            ParcoursesTheme {
                AboutScreen("1.0 (1)", {}, accountDeletionActions = AccountDeletionActions(onRequest = { deletions++ }))
            }
        }
        rule.onNodeWithText(text(R.string.account_title)).assertDoesNotExist()
        rule.onNodeWithText(text(R.string.about_privacy_deletion)).assertExists()
        rule.onNodeWithTag(TAG_ACCOUNT_DELETE).performScrollTo().performClick()
        assertEquals(1, deletions)
    }
}
