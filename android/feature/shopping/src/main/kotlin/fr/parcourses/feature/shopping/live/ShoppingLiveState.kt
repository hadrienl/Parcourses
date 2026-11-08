package fr.parcourses.feature.shopping.live

import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.feature.shopping.ShoppingRow
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/** Un article tel que la Live Update le montre : libellé tronqué, rayon effectif et sa place parmi les rayons. */
@Serializable
data class LiveItem(
    val id: String,
    val label: String,
    val aisleId: String,
    val aisleLabel: String? = null,
    /** Rang du rayon parmi les catégories : choisit la couleur de son segment. */
    val aisleIndex: Int = 0,
)

/**
 * Contenu de la Live Update du mode courses (#10 §9), pendant de `ShoppingActivityAttributes.ContentState` d'iOS.
 * Il ne suit qu'une visite (magasin choisi) : sans visite, rien n'est affiché.
 *
 * L'état est **autonome** : il voyage dans la notification (extras), si bien qu'après la mort du processus, l'action
 * « Cocher le suivant » retrouve l'ordre affiché sans rouvrir l'écran ni recalculer le tri.
 */
@Serializable
data class ShoppingLiveState(
    val visitId: String,
    val listId: String,
    val listName: String,
    val storeName: String?,
    /** À prendre, dans l'ordre affiché : le premier est le prochain. */
    val pending: List<LiveItem>,
    /** Déjà pris, du plus ancien au plus récent : le début de la barre. */
    val checked: List<LiveItem>,
) {
    /** Articles encore à prendre. */
    val remaining: Int get() = pending.size

    /** Articles de la visite : à prendre et déjà cochés (les introuvables n'y comptent pas, comme sur iOS). */
    val total: Int get() = pending.size + checked.size

    /** Prochain article à prendre, dans l'ordre affiché. */
    val next: LiveItem? get() = pending.firstOrNull()

    /**
     * Confronte l'état à la base : un article coché ailleurs (écran, autre appareil) passe dans [checked], un
     * article décoché revient en tête de [pending], un introuvable ou un article supprimé disparaît. L'ordre
     * affiché ne change pas : seul le mode courses recalcule le tri.
     */
    fun reconciled(items: List<ListItemEntity>): ShoppingLiveState {
        val byId = items.associateBy { it.id }
        val taken = pending.filter { byId[it.id]?.checkedAt != null }
        val returned = checked.filter { byId[it.id]?.let { item -> item.checkedAt == null } == true }
        val stillPending =
            pending.filter { byId[it.id]?.let { item -> item.checkedAt == null && item.notFoundAt == null } == true }
        val stillChecked = checked.filter { byId[it.id]?.checkedAt != null }
        val next =
            copy(
                pending = returned.filter { byId.getValue(it.id).notFoundAt == null } + stillPending,
                checked = stillChecked + taken,
            )
        return if (next == this) this else next
    }

    /** Reprise de compte : visite, liste et articles changent d'identifiant, l'état ne change pas. */
    fun remapped(remap: IdentifierRemap): ShoppingLiveState {
        fun List<LiveItem>.remapped() = map { it.copy(id = remap[it.id]) }
        return copy(
            visitId = remap[visitId],
            listId = remap[listId],
            pending = pending.remapped(),
            checked = checked.remapped(),
        )
    }

    fun encode(): String = json.encodeToString(serializer(), this)

    companion object {
        /** Comme iOS : un libellé démesuré n'a rien à faire sur l'écran verrouillé. */
        const val MAX_LABEL_LENGTH = 60

        private val json = Json { ignoreUnknownKeys = true }

        /** `null` si [text] n'est pas un état lisible (autre version de l'app, extras corrompus). */
        fun decode(text: String?): ShoppingLiveState? =
            text?.let {
                try {
                    json.decodeFromString(serializer(), it)
                } catch (ignored: SerializationException) {
                    null
                } catch (ignored: IllegalArgumentException) {
                    null
                }
            }

        /**
         * État à partir de l'écran. [displayed] : les lignes à prendre dans l'ordre **affiché** (par rayon en ordre
         * générique, fil continu en ordre appris) ; une ligne juste cochée y reste le temps du tri, elle compte comme
         * prise. [basket] : les articles cochés, du plus récent au plus ancien.
         */
        @Suppress("LongParameterList") // Tout ce que montre la notification, sans dépendre du modèle de l'écran.
        fun make(
            visitId: String,
            listId: String,
            listName: String,
            storeName: String?,
            displayed: List<ShoppingRow>,
            basket: List<ShoppingRow>,
            aisleLabel: (String) -> String?,
            aisleIndex: (String) -> Int,
        ): ShoppingLiveState {
            fun ShoppingRow.live() =
                LiveItem(
                    id = id,
                    label = truncated(label),
                    aisleId = aisleId,
                    aisleLabel = aisleLabel(aisleId)?.let(::truncated),
                    aisleIndex = aisleIndex(aisleId),
                )
            return ShoppingLiveState(
                visitId = visitId,
                listId = listId,
                listName = truncated(listName),
                storeName = storeName?.let(::truncated),
                pending = displayed.filter { !it.isChecked }.map { it.live() },
                checked = basket.asReversed().map { it.live() } + displayed.filter { it.isChecked }.map { it.live() },
            )
        }

        /** Coupe à [MAX_LABEL_LENGTH] caractères sans séparer une paire de substitution (émoji). */
        fun truncated(text: String): String {
            if (text.length <= MAX_LABEL_LENGTH) return text
            val end = if (text[MAX_LABEL_LENGTH - 1].isHighSurrogate()) MAX_LABEL_LENGTH - 1 else MAX_LABEL_LENGTH
            return text.substring(0, end).trimEnd() + "…"
        }
    }
}
