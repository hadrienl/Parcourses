package fr.parcourses.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import androidx.savedstate.serialization.SavedStateConfiguration
import fr.parcourses.feature.lists.ListDetailRoute
import fr.parcourses.feature.lists.ListDetailViewModel
import fr.parcourses.feature.lists.ListsRoute
import fr.parcourses.feature.lists.ListsViewModel
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.modules.SerializersModule
import kotlinx.serialization.modules.polymorphic
import kotlinx.serialization.modules.subclass
import kotlin.uuid.Uuid

/** Routes de la pile (#10 §8.1). Les suivantes arrivent avec leurs écrans (A7 à A9). */
@Serializable
sealed interface Route : NavKey {
    @Serializable
    data object Lists : Route

    /**
     * [slot] identifie l'écran, pas la liste : si la liste change d'identifiant (reprise de compte), la clé change
     * mais pas l'écran, qui garde son état et sa saisie en cours.
     */
    @Serializable
    data class ListDetail(
        val listId: String,
        val slot: String = Uuid.random().toString(),
    ) : Route
}

private val routeConfiguration =
    SavedStateConfiguration {
        serializersModule =
            SerializersModule {
                polymorphic(NavKey::class) {
                    subclass(Route.Lists::class)
                    subclass(Route.ListDetail::class)
                }
            }
    }

/** Une seule activité, une pile de routes, un ViewModel par entrée. */
@Composable
fun ParcoursesNavHost(container: AppContainer) {
    val backStack = rememberNavBackStack(routeConfiguration, Route.Lists)

    // Reprise de compte : les écrans ouverts suivent leurs nouveaux identifiants.
    LaunchedEffect(container) {
        (container.engine?.remaps ?: emptyFlow()).collect { remap ->
            backStack.forEachIndexed { index, key ->
                if (key is Route.ListDetail) backStack[index] = key.copy(listId = remap[key.listId])
            }
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
                        viewModel(factory = viewModelFactory { initializer { ListsViewModel(container.lists) } })
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
                    ListDetailRoute(viewModel = model, onBack = { backStack.removeLastOrNull() })
                }
            },
    )
}
