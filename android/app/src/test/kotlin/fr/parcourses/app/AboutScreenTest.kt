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
import fr.parcourses.core.designsystem.ParcoursesTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * À propos (#87, lot 87.8) : lien vers la politique de confidentialité, et textes sur les données d'un compte anonyme.
 * Le compte e-mail, dont « Vos données » est dans l'écran Compte (#108), est couvert par [AccountScreenTest].
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
        localOnly: Boolean = false,
        confirming: Boolean = false,
    ) {
        val deletion = AccountDeletionUiState(confirming = confirming, localOnly = localOnly)
        rule.setContent {
            CompositionLocalProvider(LocalUriHandler provides uriHandler) {
                ParcoursesTheme { AboutScreen("1.0 (1)", {}, accountDeletion = deletion) }
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
        show()

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
        show(localOnly = true)

        rule.onNodeWithTag(TAG_PRIVACY_POLICY).performScrollTo().assertIsDisplayed()
        // Sans serveur, rien n'en part : pas de phrase sur la suppression côté serveur.
        assertAbsent(R.string.about_privacy_deletion)
        assertShown(R.string.about_account_body_local)
    }

    @Test
    fun anAnonymousAccountIsDescribedByItsIdentifier() {
        show()

        assertShown(R.string.about_privacy_data)
        assertShown(R.string.about_privacy_deletion)
        assertShown(R.string.about_account_body)
        assertAbsent(R.string.about_privacy_data_email)
        assertAbsent(R.string.about_privacy_deletion_account)
        assertAbsent(R.string.about_account_body_email)
    }

    /** #122 : un compte anonyme ne peut pas partager de liste, sa confirmation n'en parle pas. Même texte qu'iOS. */
    @Test
    fun theConfirmationOfAnAnonymousAccountSaysNothingAboutSharedLists() {
        show(confirming = true)

        val body = text(R.string.about_account_confirm_body)
        rule.onNodeWithText(body).assertIsDisplayed()
        assertEquals(
            "Vos listes, vos visites et vos articles cochés seront effacés de cet appareil et de nos serveurs, ainsi " +
                "que votre identifiant anonyme. Votre contribution anonyme au plan des rayons des magasins est " +
                "conservée. C'est définitif.",
            body,
        )
        assertFalse(body.contains(SHARED_LISTS))
    }

    internal companion object {
        /**
         * #87, lot 87.8 : à la suppression, une liste partagée change de propriétaire au lieu de disparaître. Compte
         * e-mail seulement (#122).
         */
        const val SHARED_LISTS = "Une liste que vous partagez avec d'autres passe à l'un de ses membres."
    }
}
