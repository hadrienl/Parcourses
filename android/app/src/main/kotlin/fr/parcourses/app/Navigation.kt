package fr.parcourses.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import kotlinx.coroutines.flow.emptyFlow

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

    // Reprise de compte : les écrans ouverts suivent leurs nouveaux identifiants.
    LaunchedEffect(container) {
        (container.engine?.remaps ?: emptyFlow()).collect { remap ->
            backStack.applyRemap(remap)
        }
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
            container.linkedVisit(visitId)?.let { backStack.openLinkedShopping(it) }
        }
    }

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
                                            container.engine?.remaps ?: emptyFlow(),
                                        )
                                    }
                                },
                        )
                    ListsRoute(
                        viewModel = model,
                        onOpen = { id ->
                            // Un double appui ne doit pas empiler deux fois le même écran.
                            val top = backStack.lastOrNull()
                            if (top !is Route.ListDetail || top.listId != id) backStack.add(Route.ListDetail(id))
                        },
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
                                            remaps = container.engine?.remaps ?: emptyFlow(),
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
                                            remaps = container.engine?.remaps ?: emptyFlow(),
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
