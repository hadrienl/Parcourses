package fr.parcourses.app

import android.app.Application
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.designsystem.ParcoursesTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import kotlin.time.Clock

/**
 * « Supprimer mes données » (#68) de bout en bout dans l'app, build sans Supabase : À propos → Supprimer → Annuler ne
 * fait rien ; → Supprimer affiche le message, puis l'écran Listes vide. Libellés lus par TalkBack.
 */
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class AccountDeletionScreenTest {
    @get:Rule
    val rule = createComposeRule()

    private val app = RuntimeEnvironment.getApplication()
    private val container =
        AppContainer(app, config = null) { context ->
            ParcoursesDatabaseFactory.createInMemory(context, Dispatchers.IO, AndroidSQLiteDriver())
        }

    private val text = { id: Int -> app.getString(id) }

    @Before
    fun setUp() {
        container.deletionFlag.clear()
        runBlocking {
            container.categories.seedIfNeeded()
            container.lists.createList("Courses de la semaine", Clock.System.now())
        }
        rule.setContent { ParcoursesTheme { ParcoursesNavHost(container) } }
    }

    @After
    fun tearDown() = container.database.close()

    private fun openAbout() {
        rule.onNodeWithText("Courses de la semaine").assertIsDisplayed()
        rule.onNodeWithContentDescription("À propos").performClick()
        rule.onNodeWithTag(TAG_ACCOUNT_DELETE).performScrollTo()
    }

    @Test
    fun cancellingTheConfirmationDeletesNothing() {
        openAbout()
        rule.onNodeWithTag(TAG_ACCOUNT_DELETE).performClick()
        rule.onNodeWithText(text(R.string.about_account_confirm_title)).assertIsDisplayed()

        rule.onNodeWithTag(TAG_ACCOUNT_DELETE_CANCEL).performClick()

        rule.onNodeWithText(text(R.string.about_account_confirm_title)).assertDoesNotExist()
        assertEquals(AccountDeletionState.Idle, container.accountDeletion.state.value)
        assertFalse(container.deletionFlag.isPending)
        assertEquals(1, runBlocking { container.lists.lists().size })
    }

    @Test
    fun confirmingDeletesEverythingThenShowsTheMessageOverEmptyLists() {
        openAbout()
        rule.onNodeWithTag(TAG_ACCOUNT_DELETE).performClick()
        // Build sans Supabase : le texte ne parle que de l'appareil (§5.7).
        rule.onNodeWithText(text(R.string.about_account_confirm_body_local)).assertIsDisplayed()

        rule.onNodeWithTag(TAG_ACCOUNT_DELETE_CONFIRM).performClick()

        rule.waitUntil(5_000) { container.accountDeletion.state.value == AccountDeletionState.Done }
        rule.onNodeWithText(text(R.string.about_account_done)).assertIsDisplayed()
        rule.onNodeWithTag(TAG_ACCOUNT_OK).performClick()

        rule.onNodeWithText(text(R.string.about_account_done)).assertDoesNotExist()
        rule.onNodeWithText("Courses de la semaine").assertDoesNotExist()
        rule.onNodeWithText("Aucune liste").assertIsDisplayed()
        assertTrue(runBlocking { container.lists.lists().isEmpty() })
        assertFalse(container.deletionFlag.isPending)
        // Le référentiel des catégories est de nouveau amorcé.
        assertTrue(runBlocking { container.categories.categories().isNotEmpty() })
    }

    @Test
    fun talkBackReadsTheSectionTheButtonAndTheConfirmation() {
        openAbout()
        // Titre de section lu comme un titre, sous sa forme normale (pas en capitales).
        rule
            .onNodeWithText(text(R.string.about_account_title))
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
        rule
            .onNodeWithTag(TAG_ACCOUNT_DELETE)
            .assert(hasText(text(R.string.about_account_action)))
            .assertHasClickAction()
        rule.onNodeWithTag(TAG_ACCOUNT_DELETE).performClick()

        rule.onNodeWithTag(TAG_ACCOUNT_DELETE_CONFIRM).assert(hasText(text(R.string.about_account_confirm_action)))
        rule.onNodeWithTag(TAG_ACCOUNT_DELETE_CANCEL).assert(hasText(text(R.string.about_account_cancel)))
        rule.onNodeWithTag(TAG_ACCOUNT_DELETE_CONFIRM).performClick()

        rule.waitUntil(5_000) { container.accountDeletion.state.value == AccountDeletionState.Done }
        // Le message est annoncé dès qu'il apparaît.
        rule
            .onNodeWithTag(TAG_ACCOUNT_MESSAGE)
            .assert(hasText(text(R.string.about_account_done)))
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
    }
}
