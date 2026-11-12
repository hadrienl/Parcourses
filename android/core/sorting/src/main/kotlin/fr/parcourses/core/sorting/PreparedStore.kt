package fr.parcourses.core.sorting

import fr.parcourses.core.model.SortInput
import fr.parcourses.core.model.SortParams
import fr.parcourses.core.model.SortSnapshot

/**
 * Magasin préparé pour le tri (#30) : instantané validé une fois, graphe construit au premier
 * tri en mode appris, distances depuis chaque source calculées au premier besoin puis
 * réutilisées par les tris suivants de la visite (recalcul après chaque coche).
 *
 * Lié à une valeur immuable (instantané, paramètres) : un nouvel instantané demande un nouveau
 * `PreparedStore`. [sortItems] ne s'en sert que si [matches] est vrai ; le résultat reste donc
 * celui de `sortItems(input)`, seule la durée change. Utilisable depuis plusieurs threads.
 *
 * Mémoire : une ligne de `8 × (produits + 1)` octets par source utilisée, soit au plus une
 * centaine de lignes par visite.
 *
 * @throws fr.parcourses.core.model.SortError si l'instantané est invalide, comme `sortItems`.
 */
class PreparedStore private constructor(
    /** Instantané préparé. */
    val snapshot: SortSnapshot,
    /** Paramètres préparés : le coût des arêtes en dépend. */
    val params: SortParams,
    validated: Boolean,
) {
    constructor(snapshot: SortSnapshot, params: SortParams) : this(snapshot, params, validated = false)

    init {
        if (!validated) validateSnapshot(snapshot)
    }

    /** Graphe construit à la première utilisation (accès synchronisé par `lazy`). */
    internal val graph: StoreGraph by lazy { StoreGraph(snapshot, params) }

    /** Distances par source : indice du produit, ou [ENTRY_SOURCE] pour l'entrée. */
    private val rows = HashMap<Int, LongArray>()

    /** Vrai si [input] porte exactement cet instantané et ces paramètres. */
    fun matches(input: SortInput): Boolean = input.params == params && input.snapshot == snapshot

    /** Distances depuis l'entrée, calculées une seule fois. */
    internal fun distancesFromEntry(): LongArray = row(ENTRY_SOURCE) { graph.distancesFromEntry() }

    /** Distances depuis le produit d'indice [source], calculées une seule fois. */
    internal fun distancesFrom(source: Int): LongArray = row(source) { graph.distancesFrom(source) }

    private inline fun row(
        source: Int,
        compute: () -> LongArray,
    ): LongArray = synchronized(rows) { rows.getOrPut(source, compute) }

    internal companion object {
        private const val ENTRY_SOURCE = -1

        /** Magasin d'un seul tri : l'instantané vient d'être validé avec le reste de l'entrée. */
        fun validated(
            snapshot: SortSnapshot,
            params: SortParams,
        ): PreparedStore = PreparedStore(snapshot, params, validated = true)
    }
}
