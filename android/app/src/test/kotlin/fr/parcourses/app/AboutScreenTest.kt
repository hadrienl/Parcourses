package fr.parcourses.app

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountState
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.designsystem.ParcoursesTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * À propos (#87, lot 87.8) : lien vers la politique de confidentialité, et textes sur les données selon le type de
 * compte (identifiant anonyme ou compte e-mail).
 */
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class AboutScreenTest {
    @get:Rule
    val rule = createComposeRule()

    private val text = { id: Int -> RuntimeEnvironment.getApplication().getString(id) }
    private val opened = mutableListOf<String>()

    private val uriHandler =
        object : UriHandler {
            override fun openUri(uri: String) {
                opened += uri
            }
        }

    private fun show(
        kind: AccountKind,
        localOnly: Boolean = false,
        confirming: Boolean = false,
    ) {
        val account = AccountUiState(visible = !localOnly, account = AccountState(kind))
        val deletion = AccountDeletionUiState(confirming = confirming, localOnly = localOnly)
        rule.setContent {
            CompositionLocalProvider(LocalUriHandler provides uriHandler) {
                ParcoursesTheme {
                    AboutScreen("1.0 (1)", {}, account = account, accountDeletion = deletion)
                }
            }
        }
    }

    private fun assertShown(id: Int) {
        rule.onNodeWithText(text(id)).performScrollTo().assertIsDisplayed()
    }

    private fun assertAbsent(id: Int) {
        rule.onNodeWithText(text(id)).assertDoesNotExist()
    }

    @Test
    fun thePrivacyPolicyOpensInTheBrowserWithAnExplicitLabel() {
        show(AccountKind.Anonymous)

        rule
            .onNodeWithTag(TAG_PRIVACY_POLICY)
            .performScrollTo()
            .assert(hasText(text(R.string.about_privacy_policy)))
            .assert(
                SemanticsMatcher("libellé TalkBack explicite") {
                    it.config.getOrElseNullable(SemanticsActions.OnClick) { null }?.label ==
                        text(R.string.about_privacy_policy_action)
                },
            ).performClick()

        assertEquals(listOf(PRIVACY_POLICY_URL), opened)
        assertEquals("https://parcourses.hadrien.eu/confidentialite/", PRIVACY_POLICY_URL)
    }

    @Test
    fun thePrivacyPolicyStaysWithoutServer() {
        show(AccountKind.Anonymous, localOnly = true)

        rule.onNodeWithTag(TAG_PRIVACY_POLICY).performScrollTo().assertIsDisplayed()
        // Sans serveur, rien n'en part : pas de phrase sur la suppression côté serveur.
        assertAbsent(R.string.about_privacy_deletion)
        assertShown(R.string.about_account_body_local)
    }

    @Test
    fun anAnonymousAccountIsDescribedByItsIdentifier() {
        show(AccountKind.Anonymous)

        assertShown(R.string.about_privacy_data)
        assertShown(R.string.about_privacy_deletion)
        assertShown(R.string.about_account_body)
        assertAbsent(R.string.about_privacy_data_email)
        assertAbsent(R.string.about_privacy_deletion_email)
        assertAbsent(R.string.about_account_body_email)
    }

    @Test
    fun anEmailAccountIsDescribedByItsAddressAndNameWithoutTheInactivityPurge() {
        show(AccountKind.Email)

        assertShown(R.string.about_privacy_data_email)
        assertShown(R.string.about_privacy_deletion_email)
        assertShown(R.string.about_account_body_email)
        assertAbsent(R.string.about_privacy_data)
        assertAbsent(R.string.about_privacy_deletion)
        assertAbsent(R.string.about_account_body)
    }

    @Test
    fun theConfirmationNamesTheEmailAccountAndTheSharedLists() {
        show(AccountKind.Email, confirming = true)

        val body = text(R.string.about_account_confirm_body_email)
        rule.onNodeWithText(body).assertIsDisplayed()
        assertTrue(body.contains("ainsi que votre compte (adresse e-mail et prénom)."))
        assertTrue(body.contains(SHARED_LISTS))
    }

    @Test
    fun theConfirmationOfAnAnonymousAccountAlsoMentionsTheSharedLists() {
        show(AccountKind.Anonymous, confirming = true)

        val body = text(R.string.about_account_confirm_body)
        rule.onNodeWithText(body).assertIsDisplayed()
        assertTrue(body.contains("ainsi que votre identifiant anonyme. $SHARED_LISTS"))
    }

    private companion object {
        const val SHARED_LISTS = "Une liste que vous partagez avec d'autres passe à l'un de ses membres."
    }
}
