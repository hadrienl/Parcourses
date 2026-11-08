package fr.parcourses.feature.shopping

import androidx.compose.runtime.Immutable
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/** Ce que l'app sait du trajet dans ce magasin (#6). Pourcentages entiers. */
sealed interface RouteKnowledge {
    /** Pas de magasin choisi. */
    data object NoStore : RouteKnowledge

    /** Aucun instantané : ordre générique. */
    data object Unknown : RouteKnowledge

    /** Graphe trop peu fiable : ordre générique. */
    data class Learning(
        val percent: Int,
    ) : RouteKnowledge

    data class Learned(
        val percent: Int,
    ) : RouteKnowledge
}

/** Une ligne du mode courses. */
@Immutable
data class ShoppingRow(
    val id: String,
    val label: String,
    val quantity: String?,
    val isChecked: Boolean,
    /** Rayon effectif (bio compris si le magasin en a un) : celui de la section en ordre générique. */
    val aisleId: String = "",
) {
    /** « Tomates, 2 » : l'état est lu à part par TalkBack. */
    val accessibilityLabel: String get() = listOfNotNull(label, quantity).joinToString(", ")
}

/** Un rayon du mode courses : titre et articles, dans l'ordre affiché. */
@Immutable
data class ShoppingSection(
    val aisleId: String,
    val title: String,
    val rows: List<ShoppingRow>,
) {
    /** Articles encore à prendre : une ligne juste cochée reste dans sa section sans compter. */
    val remainingCount: Int get() = rows.count { !it.isChecked }
}

/** Dernière action, annulable quelques secondes. */
@Immutable
data class ShoppingUndo(
    val kind: Kind,
    val itemId: String,
    val label: String,
    /** Coche locale à retirer ; `null` sans visite. */
    val checkId: String?,
    /** Place de la ligne avant l'action. */
    val index: Int,
) {
    enum class Kind { Check, NotFound }
}

/**
 * Résumé de fin de visite. [visitId] est celui de la visite qui vient d'être close (`null` sans magasin, ou si
 * aucune coche n'a été faite : la visite n'existe alors pas) : point d'accroche de l'écran de fin complet (A9).
 */
@Immutable
data class ShoppingSummary(
    val checkedCount: Int,
    val minutes: Int,
    val storeName: String?,
    val knowledge: RouteKnowledge,
    val visitId: String? = null,
)

/** Réordonnancement à annoncer à TalkBack : [seq] distingue deux annonces identiques. */
@Immutable
data class ReorderAnnouncement(
    val seq: Int,
    /** Libellé du prochain article à prendre. */
    val next: String,
)

@Immutable
data class ShoppingUiState(
    val isLoaded: Boolean = false,
    val name: String = "",
    val storeName: String? = null,
    /** À acheter, dans l'ordre affiché. Une ligne juste cochée y reste le temps du délai d'inactivité. */
    val toBuy: List<ShoppingRow> = emptyList(),
    val basket: List<ShoppingRow> = emptyList(),
    val notFound: List<ShoppingRow> = emptyList(),
    /** Rayons (ordre non appris seulement) ; vide quand le fil du trajet est continu. */
    val sections: List<ShoppingSection> = emptyList(),
    /** Ordre non appris : les articles se lisent par rayon, avec un titre. En mode appris : fil continu. */
    val groupsByAisle: Boolean = true,
    val knowledge: RouteKnowledge = RouteKnowledge.NoStore,
    val undo: ShoppingUndo? = null,
    /** Article tout juste ajouté, à repérer un court instant. */
    val highlightedItemId: String? = null,
    /** Visite terminée d'office après 45 min : il ne reste qu'à décider des articles restants. */
    val expired: Boolean = false,
    val summary: ShoppingSummary? = null,
    val reorder: ReorderAnnouncement? = null,
    val errorMessage: String? = null,
) {
    /** Articles ni cochés ni décidés : la feuille de fin demande s'il faut les garder. */
    val remainingCount: Int get() = toBuy.count { !it.isChecked } + notFound.size

    /** À prendre, hors lignes juste cochées. */
    val toBuyCount: Int get() = toBuy.count { !it.isChecked }

    val isEverythingChecked: Boolean get() = remainingCount == 0 && !(toBuy.isEmpty() && basket.isEmpty())
}

/** Délais du mode courses, réglables par les tests. */
data class ShoppingTimings(
    /** Inactivité avant le tri en direct (#6). */
    val settle: Duration = 600.milliseconds,
    val undo: Duration = 4.seconds,
    val highlight: Duration = 300.milliseconds,
    /** Attente maximale de l'instantané du serveur au début de la visite. */
    val preload: Duration = 3.seconds,
    /** L'envoi d'une coche ne part pas pendant que « Annuler » est encore affiché. */
    val sendMargin: Duration = 1.seconds,
    /** Sans coche depuis ce délai, la visite se termine au retour au premier plan (#9 §5.5). */
    val expiry: Duration = 45.minutes,
)
