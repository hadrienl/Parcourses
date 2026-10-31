package fr.parcourses.core.model

// Modèles d'entrée et de sortie du tri (#5 §2.6). Noms identiques à ceux d'iOS
// (`SortEngine/Models.swift`) ; leur forme JSON est celle des vecteurs de
// `shared/test-vectors/sort/`. Tous les nombres sont des entiers `Long`.

/** Paramètres de l'algorithme (#5 §2.6). */
data class SortParams(
    /** Confiance minimale du graphe (en millièmes) pour utiliser le mode appris. */
    val confThresholdQ: Long,
    /** Échelle du coût d'une arête : `edgeCost(w) = COST_SCALE × 1000 / (1000 + w)`. */
    val costScale: Long,
    /** Coût de base du repli par catégorie. */
    val unknownBase: Long,
    /** Coût ajouté par écart d'une catégorie (indice ordinal). */
    val catStep: Long,
    /** Nombre maximal de passes 2-opt (0 : glouton seul). */
    val twoOptMaxPasses: Long,
    /** Gain minimal, en pourcentage, pour abandonner l'ordre précédent. */
    val reorderMinGainPct: Long,
) {
    companion object {
        /** Valeurs par défaut de #5, identiques à `DEFAULT_PARAMS` de la référence. */
        val Default =
            SortParams(
                confThresholdQ = 500,
                costScale = 1000,
                unknownBase = 3000,
                catStep = 200,
                twoOptMaxPasses = 20,
                reorderMinGainPct = 10,
            )
    }
}

/** Catégorie : seul l'ordre `(rank, id)` compte, jamais l'échelle de `rank`. */
data class SortCategory(
    val id: String,
    val rank: Long,
)

/** Lien appris entre l'entrée du magasin et un produit. */
data class SnapshotEntry(
    val productId: String,
    val weightQ: Long,
)

/** Arête non orientée du graphe de voisinage entre deux produits. */
data class SnapshotEdge(
    val a: String,
    val b: String,
    val weightQ: Long,
)

/** Copie locale du graphe d'un magasin, telle que publiée par le serveur. */
data class SortSnapshot(
    val confidenceQ: Long,
    val entries: List<SnapshotEntry>,
    val edges: List<SnapshotEdge>,
)

/** Article restant à trier. */
data class SortItem(
    val id: String,
    /** Produit du catalogue ; `null` pour un texte libre. */
    val productId: String?,
    /** Catégorie ; `null` ou inconnue : celle de `other`, sinon la dernière. */
    val categoryId: String?,
    /** Libellé normalisé (#7), comparé octet par octet en UTF-8 dans le repli. */
    val normalizedName: String,
)

/**
 * Point de départ du trajet, résolu par l'app : le dernier article coché ayant un produit,
 * sinon l'entrée du magasin.
 */
sealed interface SortStart {
    /** Entrée du magasin. */
    data object Entry : SortStart

    /** Dernier produit coché. */
    data class Product(
        val productId: String,
    ) : SortStart
}

/** Entrée complète du tri, immuable. */
data class SortInput(
    val params: SortParams = SortParams.Default,
    val categories: List<SortCategory>,
    /** `null` : magasin inconnu, d'où le repli par catégorie. */
    val snapshot: SortSnapshot?,
    val items: List<SortItem>,
    val start: SortStart,
    /** Ordre affiché juste avant (hystérésis) ; `null` et liste vide sont équivalents. */
    val previousOrder: List<String>?,
)

/** Résultat du tri. */
data class SortOutput(
    /** Mode utilisé : graphe appris ou repli par catégorie. */
    val mode: Mode,
    /** Identifiants des articles, dans l'ordre du trajet. */
    val order: List<String>,
    /** Coût entier du chemin retenu, départ compris ; `null` en repli. */
    val cost: Long?,
) {
    /** Mode de tri ; [wireName] est la valeur des vecteurs (`learned`, `fallback`). */
    enum class Mode(
        val wireName: String,
    ) {
        Learned("learned"),
        Fallback("fallback"),
    }
}

/** Entrée refusée par la validation : on refuse plutôt que de deviner. */
sealed class SortError(
    message: String,
) : IllegalArgumentException(message) {
    /** Identifiant hors de `[0-9a-z-]+` ; [field] dit où il a été trouvé. */
    class InvalidId(
        val field: String,
        val value: String,
    ) : SortError("$field invalide (attendu [0-9a-z-]+) : \"$value\"")

    class DuplicateCategory(
        val id: String,
    ) : SortError("catégorie en double : $id")

    class DuplicateItem(
        val id: String,
    ) : SortError("identifiant d'article en double : $id")

    /** Poids négatif ; [context] désigne l'arête ou l'entrée fautive. */
    class NegativeWeight(
        val context: String,
        val weightQ: Long,
    ) : SortError("weight_q invalide : $context $weightQ")
}
