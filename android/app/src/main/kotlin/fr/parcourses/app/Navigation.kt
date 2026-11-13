package fr.parcourses.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import fr.parcourses.feature.lists.ListDetailRoute
import fr.parcourses.feature.lists.ListDetailViewModel
import fr.parcourses.feature.lists.ListsRoute
import fr.parcourses.feature.lists.ListsViewModel
import fr.parcourses.feature.shopping.ShoppingRoute
import fr.parcourses.feature.shopping.ShoppingSummaryRoute
import fr.parcourses.feature.shopping.ShoppingViewModel
import fr.parcourses.feature.shopping.live.NotificationPermissionPrompt
import fr.parcourses.feature.storepicker.StorePickerRoute
import fr.parcourses.feature.storepicker.StorePickerViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Une seule activité, une pile de routes, un ViewModel par entrée. [coldStart] : l'activité démarre sans état
 * sauvegardé (ni recréation ni restauration après la mort du processus).
 */
@Suppress("LongMethod")
@Composable
fun ParcoursesNavHost(
    container: AppContainer,
    coldStart: Boolean = false,
) {
    val backStack = rememberNavBackStack(routeConfiguration, Route.Lists)
    // Clé de session illisible : pastille sur À propos, qui propose de réinitialiser la session (#51).
    val sessionStuckFlow = remember(container) { container.sessionMaintenance?.isSessionStorageStuck ?: NotStuck }

    val deletion by container.accountDeletion.state.collectAsState()

    // Reprise de compte : les écrans ouverts suivent leurs nouveaux identifiants.
    LaunchedEffect(container) {
        container.remaps.collect { remap ->
            backStack.applyRemap(remap)
        }
    }

    // Données supprimées (#68) : l'état de l'app a été recréé, la navigation repart sur les listes, pile vidée.
    LaunchedEffect(container) {
        container.generation.collect { if (container.consumeNavigationReset()) backStack.resetToLists() }
    }

    // Suppression en cours : le mode courses se ferme, sans `closeVisit` (la visite va être effacée).
    LaunchedEffect(deletion) {
        if (deletion == AccountDeletionState.Running) backStack.closeShopping()
    }

    // Choix du magasin : le collecteur est ici car cette composition ne quitte jamais l'écran (voir `storeChoices`).
    LaunchedEffect(container) {
        container.storeChoices.collect { choice -> backStack.openShopping(choice) }
    }

    // Reprise au lancement d'une visite restée ouverte : une fois par processus, jamais sur une recréation. Ensuite,
    // une Live Update qui ne suit pas la visite ouverte (expirée, abandonnée) est retirée.
    LaunchedEffect(container) {
        backStack.resumeOnLaunch(container.launchResume, coldStart) { container.resumableVisit() }
        container.liveUpdates.reconcile()
    }

    // Live Update touchée : le mode courses de sa visite, si elle est encore ouverte. Collecteur toujours composé.
    LaunchedEffect(container) {
        container.shoppingLinks.collect { visitId ->
            // `linkedVisit` ne rend rien pendant une suppression des données.
            container.linkedVisit(visitId)?.let { backStack.openLinkedShopping(it) }
        }
    }

    // Voile et messages de la suppression, par-dessus tous les écrans.
    AccountDeletionOverlay(
        deletion,
        AccountDeletionOverlayActions(
            onAcknowledge = container.accountDeletion::acknowledge,
            onRetry = { container.accountDeletion.start() },
            onCancel = { container.accountDeletion.cancel() },
        ),
        localOnly = container.isLocalOnly,
    )

    NavDisplay(
        backStack = backStack,
        onBack = { backStack.removeLastOrNull() },
        entryDecorators =
            listOf(
                rememberSaveableStateHolderNavEntryDecorator(),
                rememberViewModelStoreNavEntryDecorator(),
            ),
        entryProvider =
            entryProvider {
                entry<Route.Lists> {
                    val model: ListsViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        ListsViewModel(
                                            container.lists,
                                            container.remaps,
                                        )
                                    }
                                },
                        )
                    val sessionStuck by sessionStuckFlow.collectAsState()
                    ListsRoute(
                        viewModel = model,
                        // Appui sur une liste, ou liste qui vient d'être créée : voir `openListFromLists`.
                        onOpen = { id -> backStack.openListFromLists(id) },
                        onAbout = { if (backStack.lastOrNull() != Route.About) backStack.add(Route.About) },
                        aboutNeedsAttention = sessionStuck,
                    )
                }
                entry<Route.About> {
                    val reset: SessionResetViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer { SessionResetViewModel(sessionStuckFlow, container::resetSession) }
                                },
                        )
                    val resetState by reset.state.collectAsState()
                    val deletionModel: AccountDeletionViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        AccountDeletionViewModel(
                                            deletion = container.accountDeletion.state,
                                            hasOpenVisit = { container.visits.openVisit() != null },
                                            start = container.accountDeletion::start,
                                            localOnly = container.isLocalOnly,
                                        )
                                    }
                                },
                        )
                    val deletionState by deletionModel.state.collectAsState()
                    AboutScreen(
                        version = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                        onBack = { if (backStack.lastOrNull() == Route.About) backStack.removeLastOrNull() },
                        sessionReset = resetState,
                        sessionResetActions = reset.actions,
                        accountDeletion = deletionState,
                        accountDeletionActions = deletionModel.actions,
                    )
                }
                entry<Route.ListDetail>(clazzContentKey = { it.slot }) { key ->
                    val model: ListDetailViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        ListDetailViewModel(
                                            listId = key.listId,
                                            lists = container.lists,
                                            products = container.products,
                                            categories = container.categories,
                                            analyzer = container.analyzer,
                                            remaps = container.remaps,
                                        )
                                    }
                                },
                        )
                    ListDetailRoute(
                        viewModel = model,
                        onBack = { backStack.popIfTop(key.slot) },
                        onStartShopping = { listId -> backStack.openStorePicker(listId) },
                    )
                }
                entry<Route.StorePicker>(clazzContentKey = { it.slot }) { key ->
                    val model: StorePickerViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        StorePickerViewModel(
                                            container.location,
                                            container.gateway,
                                            container.stores,
                                            container.locationPermission,
                                        )
                                    }
                                },
                        )
                    StorePickerRoute(
                        viewModel = model,
                        // Le mode courses reprend ce choix : voir `storeChoices`.
                        onOutcome = { outcome ->
                            backStack.finishStorePicker(key.slot, outcome)?.let(container::offerStoreChoice)
                        },
                        onBack = { backStack.popIfTop(key.slot) },
                    )
                }
                entry<Route.Shopping>(clazzContentKey = { it.slot }) { key ->
                    val model: ShoppingViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        ShoppingViewModel(
                                            listId = key.listId,
                                            storeId = key.storeId,
                                            deps = container.shopping,
                                            remaps = container.remaps,
                                        )
                                    }
                                },
                        )
                    ShoppingRoute(
                        viewModel = model,
                        onBack = { backStack.popIfTop(key.slot) },
                        onClose = { backStack.popIfTop(key.slot) },
                        onFinished = { summary -> backStack.finishShopping(key.slot, summary) },
                    )
                    // Live Update : seulement avec un magasin (une visite à suivre).
                    if (key.storeId != null) {
                        NotificationPermissionPrompt(
                            container.livePreferences,
                            onGranted = container.liveUpdates::refresh,
                        )
                    }
                }
                entry<Route.ShoppingSummary>(clazzContentKey = { it.slot }) { key ->
                    ShoppingSummaryRoute(summary = key.summary, onClose = { backStack.popIfTop(key.slot) })
                }
            },
    )
}

/** Sans Supabase, pas de session : rien à réinitialiser. */
private val NotStuck: StateFlow<Boolean> = MutableStateFlow(false)
