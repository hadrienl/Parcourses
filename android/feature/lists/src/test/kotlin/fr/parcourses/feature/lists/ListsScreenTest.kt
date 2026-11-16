package fr.parcourses.feature.lists

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertTouchHeightIsEqualTo
import androidx.compose.ui.test.assertTouchWidthIsEqualTo
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountEntry
import fr.parcourses.core.data.repository.ListSummary
import fr.parcourses.core.designsystem.ParcoursesTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ListsScreenTest {
    @get:Rule
    val rule = createComposeRule()

    private val opened = mutableListOf<String>()
    private val created = mutableListOf<String>()
    private val renamed = mutableListOf<Pair<String, String>>()
    private val deleted = mutableListOf<String>()
    private var dismissed = 0

    private fun show(
        state: ListsUiState,
        onAbout: (() -> Unit)? = null,
        aboutNeedsAttention: Boolean = false,
    ) {
        rule.setContent {
            ParcoursesTheme {
                ListsScreen(
                    state = state,
                    onOpen = { opened += it },
                    onCreate = { created += it },
                    onRename = { id, name -> renamed += id to name },
                    onDelete = { deleted += it },
                    onDismissError = { dismissed++ },
                    onAbout = onAbout,
                    aboutNeedsAttention = aboutNeedsAttention,
                )
            }
        }
    }

    private val lists =
        listOf(
            ListSummary("a", "Semaine", remaining = 2, total = 3),
            ListSummary("b", "Week-end", remaining = 0, total = 4),
            ListSummary("c", "Vide", remaining = 0, total = 0),
            ListSummary("d", "Un seul", remaining = 1, total = 1),
        )

    @Test
    fun nothingIsShownBeforeTheFirstRead() {
        show(ListsUiState(isLoaded = false))
        rule.onNodeWithText("Aucune liste").assertDoesNotExist()
        rule.onNodeWithTag(TAG_NEW_LIST).assertExists()
    }

    @Test
    fun theEmptyStateInvitesToCreateAList() {
        show(ListsUiState(isLoaded = true))
        rule.onNodeWithText("Aucune liste").assertExists()
        rule.onNodeWithText("Créez votre première liste de courses.").assertExists()
    }

    @Test
    fun eachListShowsItsNameAndItsRemainingCount() {
        show(ListsUiState(lists = lists, isLoaded = true))
        rule.onNodeWithText("Semaine").assertExists()
        rule.onNodeWithText("2 articles restants").assertExists()
        rule.onNodeWithText("Tout est coché").assertExists()
        rule.onNodeWithText("Aucun article").assertExists()
        rule.onNodeWithText("1 article restant").assertExists()
    }

    @Test
    fun tappingAListOpensIt() {
        show(ListsUiState(lists = lists, isLoaded = true))
        rule.onNodeWithText("Week-end").performClick()
        assertEquals(listOf("b"), opened)
    }

    @Test
    fun creatingAListNeedsANameAndTrimsNothingItself() {
        show(ListsUiState(isLoaded = true))
        rule.onNodeWithTag(TAG_NEW_LIST).performClick()
        rule.onNodeWithTag(TAG_CONFIRM_NAME).assertIsNotEnabled()
        rule.onNodeWithTag(TAG_NAME_FIELD).performTextInput("Courses")
        rule.onNodeWithTag(TAG_CONFIRM_NAME).assertIsEnabled().performClick()
        assertEquals(listOf("Courses"), created)
        rule.onNodeWithTag(TAG_NAME_FIELD).assertDoesNotExist()
    }

    @Test
    fun renamingStartsFromTheCurrentName() {
        show(ListsUiState(lists = lists, isLoaded = true))
        rule.onNodeWithContentDescription("Actions pour Semaine").performClick()
        rule.onNodeWithText("Renommer").performClick()
        rule.onNodeWithText("Renommer la liste").assertExists()
        rule.onNodeWithTag(TAG_NAME_FIELD).assertTextContains("Semaine")
        rule.onNodeWithTag(TAG_NAME_FIELD).performTextInput(" 2")
        rule.onNodeWithTag(TAG_CONFIRM_NAME).performClick()
        assertEquals(listOf("a" to "Semaine 2"), renamed)
    }

    @Test
    fun deletingAsksForConfirmation() {
        show(ListsUiState(lists = lists, isLoaded = true))
        rule.onNodeWithContentDescription("Actions pour Week-end").performClick()
        rule.onNodeWithText("Supprimer").performClick()
        rule.onNodeWithText("Supprimer cette liste et ses articles ?").assertExists()
        assertEquals(emptyList<String>(), deleted)
        rule.onNodeWithTag(TAG_CONFIRM_DELETE).performClick()
        assertEquals(listOf("b"), deleted)
    }

    @Test
    fun cancellingTheConfirmationDeletesNothing() {
        show(ListsUiState(lists = lists, isLoaded = true))
        rule.onNodeWithContentDescription("Actions pour Week-end").performClick()
        rule.onNodeWithText("Supprimer").performClick()
        rule.onNodeWithText("Annuler").performClick()
        assertEquals(emptyList<String>(), deleted)
    }

    @Test
    fun anErrorIsShownThenAcknowledged() {
        show(ListsUiState(lists = lists, isLoaded = true, errorDetail = "Cet élément n'existe plus."))
        rule.onNodeWithText("L'opération a échoué : Cet élément n'existe plus.").assertExists()
        rule.onNodeWithText("OK").performClick()
        assertEquals(1, dismissed)
    }

    @Test
    fun aDialogOnAListThatChangedIdentifierCloses() {
        var state by androidx.compose.runtime.mutableStateOf(ListsUiState(lists = lists, isLoaded = true))
        rule.setContent {
            ParcoursesTheme {
                ListsScreen(state, {}, {}, { _, _ -> }, { deleted += it }, {})
            }
        }
        rule.onNodeWithContentDescription("Actions pour Week-end").performClick()
        rule.onNodeWithText("Supprimer").performClick()
        rule.onNodeWithText("Supprimer cette liste et ses articles ?").assertExists()
        // Reprise de compte : la liste revient sous un autre identifiant.
        state = ListsUiState(lists = lists.map { if (it.id == "b") it.copy(id = "b2") else it }, isLoaded = true)
        rule.waitForIdle()
        rule.onNodeWithText("Supprimer cette liste et ses articles ?").assertDoesNotExist()
        assertEquals(emptyList<String>(), deleted)
    }

    @Test
    fun aboutCarriesABadgeOnlyWhenItNeedsAttention() {
        var needsAttention by mutableStateOf(false)
        rule.setContent {
            ParcoursesTheme {
                ListsScreen(
                    state = ListsUiState(isLoaded = true),
                    onOpen = {},
                    onCreate = {},
                    onRename = { _, _ -> },
                    onDelete = {},
                    onDismissError = {},
                    onAbout = {},
                    aboutNeedsAttention = needsAttention,
                )
            }
        }
        rule.onNodeWithTag(TAG_ABOUT_BADGE, useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithContentDescription("À propos").assertExists()
        needsAttention = true
        rule.onNodeWithTag(TAG_ABOUT_BADGE, useUnmergedTree = true).assertExists()
        rule.onNodeWithContentDescription("À propos, action requise").assertExists()
    }

    @Test
    fun anAnonymousAccountOffersToSignInAndALostSessionAsksToReconnect() {
        var account by mutableStateOf(ListsAccountUi())
        var signIns = 0
        var anonymous = 0
        rule.setContent {
            ParcoursesTheme {
                ListsScreen(
                    state = ListsUiState(isLoaded = true),
                    onOpen = {},
                    onCreate = {},
                    onRename = { _, _ -> },
                    onDelete = {},
                    onDismissError = {},
                    onAbout = {},
                    account = account,
                )
            }
        }
        // Sans serveur : pas de bouton compte.
        rule.onNodeWithTag(TAG_SIGN_IN).assertDoesNotExist()
        rule.onNodeWithTag(TAG_ACCOUNT).assertDoesNotExist()
        rule.onNodeWithTag(TAG_SESSION_BANNER).assertDoesNotExist()

        // « Se connecter » en haut, et sous les listes l'invitation reçue par un anonyme (#87) : le bouton du haut.
        account = ListsAccountUi(entry = AccountEntry.SignIn, onSignIn = { signIns++ })
        rule.onNodeWithTag(TAG_SIGN_IN).performClick()
        assertEquals(1, signIns)

        // Compte e-mail sans session : bandeau, reconnexion, ou compte anonyme après confirmation.
        account =
            ListsAccountUi(
                entry = AccountEntry.Account("H"),
                displayName = "Hadrien",
                needsSignIn = true,
                onSignIn = { signIns++ },
                onContinueWithoutAccount = { anonymous++ },
            )
        rule.onNodeWithTag(TAG_SIGN_IN).assertDoesNotExist()
        // La pastille reste, et dit que la session est perdue.
        rule.onNodeWithContentDescription("Compte, Hadrien. Reconnectez-vous pour synchroniser").assertExists()
        rule.onNodeWithText("Reconnectez-vous pour synchroniser.").assertExists()
        rule.onNodeWithTag(TAG_SESSION_RECONNECT).performClick()
        assertEquals(2, signIns)
        rule.onNodeWithTag(TAG_SESSION_ANONYMOUS).performClick()
        rule.onNodeWithText("Continuer sans compte ?").assertExists()
        assertEquals(0, anonymous)
        rule.onNodeWithTag(TAG_ANONYMOUS_CONFIRM).performClick()
        assertEquals(1, anonymous)
        rule.onNodeWithText("Continuer sans compte ?").assertDoesNotExist()
    }

    private fun showAccount(account: () -> ListsAccountUi) {
        rule.setContent {
            ParcoursesTheme {
                ListsScreen(
                    state = ListsUiState(isLoaded = true),
                    onOpen = {},
                    onCreate = {},
                    onRename = { _, _ -> },
                    onDelete = {},
                    onDismissError = {},
                    onAbout = {},
                    account = account(),
                )
            }
        }
    }

    @Test
    fun aSignedInAccountKeepsAnAccountButtonThatOpensTheAccountScreen() {
        var accounts = 0
        var signIns = 0
        showAccount {
            ListsAccountUi(
                entry = AccountEntry.Account("H"),
                displayName = "Hadrien",
                onSignIn = { signIns++ },
                onAccount = { accounts++ },
            )
        }
        rule.onNodeWithTag(TAG_SIGN_IN).assertDoesNotExist()
        rule.onNodeWithTag(TAG_ACCOUNT_INITIAL, useUnmergedTree = true).assertExists()
        rule
            .onNodeWithTag(TAG_ACCOUNT)
            .assert(hasContentDescription("Compte, Hadrien"))
            .assertHasClickAction()
            // « Appuyez deux fois pour ouvrir votre compte » (iOS : indication « Ouvre votre compte »).
            .assert(
                SemanticsMatcher("ouvre le compte") {
                    it.config.getOrNull(SemanticsActions.OnClick)?.label == "ouvrir votre compte"
                },
            ).assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
            .assertIsEnabled()
            .assertTouchHeightIsEqualTo(48.dp)
            .assertTouchWidthIsEqualTo(48.dp)
            .performClick()
        assertEquals(1, accounts)
        assertEquals(0, signIns)
        // Un compte e-mail n'est pas invité à se connecter sous les listes.
        rule.onNodeWithText("Se connecter").assertDoesNotExist()
    }

    @Test
    fun withoutAFirstNameTheAccountButtonShowsAPerson() {
        showAccount { ListsAccountUi(entry = AccountEntry.Account(null), displayName = " ") }
        rule.onNodeWithTag(TAG_ACCOUNT_INITIAL, useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithTag(TAG_ACCOUNT).assert(hasContentDescription("Compte"))
    }

    @Test
    fun theAccountButtonStaysVisibleButDisabledDuringAnUnfinishedSignOut() {
        var account by mutableStateOf(ListsAccountUi(entry = AccountEntry.Account("H"), entryEnabled = false))
        showAccount { account }
        rule.onNodeWithTag(TAG_ACCOUNT).assertIsNotEnabled()

        // Compte redevenu anonyme, purge pas finie : « Se connecter » reste visible, désactivé.
        account = ListsAccountUi(entry = AccountEntry.SignIn, entryEnabled = false)
        rule.onNodeWithTag(TAG_SIGN_IN).assertIsNotEnabled()
        rule.onNodeWithTag(TAG_SIGN_IN).assertHeightIsAtLeast(48.dp)
    }
}
