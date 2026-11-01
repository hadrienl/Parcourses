package fr.parcourses.core.categorizer

/** Nature de la correspondance trouvée par le classifieur. */
enum class MatchKind(
    /** Valeur dans les vecteurs partagés. */
    val wireName: String,
) {
    /** Modificateur prioritaire (« surgelé »…). */
    Override("override"),

    /** Nom de produit ou expression du dictionnaire. */
    Keyword("keyword"),

    /** Marque, retenue faute de nom de produit. */
    Brand("brand"),

    /** Aucune correspondance : catégorie `other`. */
    None("none"),
}

/** Résultat de la classification d'un libellé. */
data class Classification(
    /** Forme normalisée du libellé (sans quantités ni mots vides, au singulier). */
    val normalized: String,
    /** Catégorie retenue, `other` à défaut. */
    val categoryId: String,
    /** Clé du dictionnaire qui a décidé, `null` si aucune. */
    val matchedKeyword: String?,
    /** Nature de la correspondance. */
    val match: MatchKind,
)

/**
 * Classifieur déterministe par mots-clés (#7 §2.3), identique à `shared/reference/classify.ts`.
 *
 * Correspondance exacte sur la forme normalisée, sans distance d'édition. Immuable : on le
 * construit une fois et on le partage entre threads.
 */
class CategoryClassifier(
    dictionary: KeywordDictionary,
    rules: NormalizationRules,
) {
    /** Classifieur sur le dictionnaire français embarqué, lu une seule fois par processus. */
    constructor() : this(CategoryResources.keywordDictionary(), CategoryResources.normalizationRules())

    /** Normaliseur utilisé, exposé pour calculer `normalizedName` avec les mêmes règles. */
    val normalizer = LabelNormalizer(rules)

    // associateBy : la dernière occurrence d'une clé l'emporte, comme Map.set dans la référence.
    private val keywords = dictionary.keywords.associateBy { it.k }
    private val overrides = dictionary.overrides.associate { it.k to it.c }
    private val maxWords = (dictionary.keywords + dictionary.overrides).maxOfOrNull { wordCount(it.k) } ?: 1

    /** Classe un libellé saisi librement. */
    fun classify(raw: String): Classification {
        val normalized = normalizer.normalize(raw)
        val tokens = if (normalized.isEmpty()) emptyList() else normalized.split(' ')
        val decision = matchOverride(tokens) ?: matchPhrase(tokens) ?: matchWord(tokens)
        return Classification(
            normalized = normalized,
            categoryId = decision?.categoryId ?: OTHER_CATEGORY_ID,
            matchedKeyword = decision?.key,
            match = decision?.match ?: MatchKind.None,
        )
    }

    /** 1. Modificateurs : n-gramme le plus long, puis le plus à gauche. */
    private fun matchOverride(tokens: List<String>): Decision? =
        firstNGram(tokens, minWords = 1) { it in overrides }?.let { key ->
            Decision(overrides.getValue(key), key, MatchKind.Override)
        }

    /** 2. Expression multi-mots la plus longue, la plus à gauche. */
    private fun matchPhrase(tokens: List<String>): Decision? =
        firstNGram(tokens, minWords = 2) { it in keywords }?.let(::keywordDecision)

    /** 3. Mot simple : premier nom de produit, sinon première marque. */
    private fun matchWord(tokens: List<String>): Decision? =
        (
            tokens.firstOrNull { token -> keywords[token]?.let { it.brand != true } == true }
                ?: tokens.firstOrNull { it in keywords }
        )?.let(::keywordDecision)

    private fun keywordDecision(key: String): Decision {
        val entry = keywords.getValue(key)
        return Decision(entry.c, key, if (entry.brand == true) MatchKind.Brand else MatchKind.Keyword)
    }

    /** Premier n-gramme accepté, du plus long au plus court puis de gauche à droite. */
    private fun firstNGram(
        tokens: List<String>,
        minWords: Int,
        accept: (String) -> Boolean,
    ): String? {
        for (n in minOf(maxWords, tokens.size) downTo minWords) {
            for (start in 0..tokens.size - n) {
                val key = tokens.subList(start, start + n).joinToString(" ")
                if (accept(key)) return key
            }
        }
        return null
    }

    private data class Decision(
        val categoryId: String,
        val key: String,
        val match: MatchKind,
    )

    companion object {
        /** Catégorie de repli. */
        const val OTHER_CATEGORY_ID = "other"

        private fun wordCount(key: String) = key.split(' ').size
    }
}
