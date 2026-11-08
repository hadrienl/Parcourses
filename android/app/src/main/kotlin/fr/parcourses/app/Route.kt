package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import androidx.savedstate.serialization.SavedStateConfiguration
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

internal val routeConfiguration =
    SavedStateConfiguration {
        serializersModule =
            SerializersModule {
                polymorphic(NavKey::class) {
                    subclass(Route.Lists::class)
                    subclass(Route.ListDetail::class)
                }
            }
    }
