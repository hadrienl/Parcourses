package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import androidx.savedstate.serialization.SavedStateConfiguration
import kotlinx.serialization.Serializable
import kotlinx.serialization.modules.SerializersModule
import kotlinx.serialization.modules.polymorphic
import kotlinx.serialization.modules.subclass
import kotlin.uuid.Uuid

/** Routes de la pile (#10 §8.1). L'écran de fin complet arrive avec A9. */
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

    /** Choix du magasin avant de faire les courses de [listId] (#10 §8.1). [slot] : comme pour [ListDetail]. */
    @Serializable
    data class StorePicker(
        val listId: String,
        val slot: String = Uuid.random().toString(),
    ) : Route

    /**
     * Mode courses de [listId] dans le magasin [storeId] (`null` : sans magasin, ni visite ni instantané). La
     * visite n'est pas dans la route : elle est ouverte (ou reprise) par l'écran, une visite par liste et magasin.
     * [slot] : comme pour [ListDetail].
     */
    @Serializable
    data class Shopping(
        val listId: String,
        val storeId: String?,
        val slot: String = Uuid.random().toString(),
    ) : Route
}

internal val routeConfiguration =
    SavedStateConfiguration {
        serializersModule =
            SerializersModule {
                polymorphic(NavKey::class) {
                    subclass(Route.Lists::class)
                    subclass(Route.ListDetail::class)
                    subclass(Route.StorePicker::class)
                    subclass(Route.Shopping::class)
                }
            }
    }
