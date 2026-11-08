package fr.parcourses.app

import fr.parcourses.feature.storepicker.StorePickerOutcome
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow

/**
 * Magasin choisi (ou « sans magasin ») pour faire les courses de [listId]. Le mode courses (A8) le reprend pour
 * ouvrir la visite ; la position n'y figure pas.
 */
data class StoreChoice(
    val listId: String,
    val outcome: StorePickerOutcome,
)

/**
 * Canal des choix de magasin, à consommation unique.
 *
 * Contrat : **un seul collecteur**, et il doit être **toujours composé** (le `LaunchedEffect` de
 * `ParcoursesNavHost`). Le choix est émis puis dépilé dans la même exécution, alors que l'écran Liste n'est pas
 * encore recomposé : un collecteur placé dans cet écran, ou un `SharedFlow` sans rejeu, le perdrait. Le canal garde
 * le choix jusqu'à ce que le collecteur le lise. Le collecteur doit toujours filtrer sur [StoreChoice.listId]
 * (voir `openShopping`) : un choix ne s'applique qu'à la liste pour laquelle il a été fait.
 */
class StoreChoiceEvents {
    private val channel = Channel<StoreChoice>(Channel.BUFFERED)

    val choices: Flow<StoreChoice> = channel.receiveAsFlow()

    fun offer(choice: StoreChoice) {
        channel.trySend(choice)
    }
}
