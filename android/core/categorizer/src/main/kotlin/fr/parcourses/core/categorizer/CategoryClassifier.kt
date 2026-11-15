package fr.parcourses.core.categorizer

import kotlin.math.abs

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

    /** Trouvé après correction d'une faute de frappe (#98), faute de correspondance exacte. */
    Fuzzy("fuzzy"),

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
    /** Vrai si le libellé contient « bio » ou « biologique », quelle que soit la catégorie (#28). */
    val organic: Boolean,
)

/**
 * Classifieur déterministe par mots-clés (#7 §2.3), identique à `shared/reference/classify.ts`.
 *
 * Correspondance exacte sur la forme normalisée ; faute de résultat, un mot inconnu à une faute
 * d'un mot-clé est corrigé avant de reclasser (#98). Immuable : on le construit une fois et on le
 * partage entre threads.
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

    /** Tous les mots des clés et des modificateurs : un mot connu n'est jamais corrigé. */
    private val vocabulary: Set<String> = (keywords.keys + overrides.keys).flatMap { it.split(' ') }.toSet()

    /** Mots-clés d'un seul mot, cibles des corrections. */
    private val singleWords: List<KeywordEntry> = keywords.values.filter { ' ' !in it.k }

    /** Classe un libellé saisi librement. */
    fun classify(raw: String): Classification {
        val normalized = normalizer.normalize(raw)
        val words = if (normalized.isEmpty()) emptyList() else normalized.split(' ')
        val tokens = words.filter { it !in ORGANIC_WORDS }
        val decision = decide(tokens) ?: decideCorrected(tokens)
        return Classification(
            normalized = normalized,
            categoryId = decision?.categoryId ?: OTHER_CATEGORY_ID,
            matchedKeyword = decision?.key,
            match = decision?.match ?: MatchKind.None,
            organic = tokens.size != words.size,
        )
    }

    /** Correspondance exacte : modificateurs, expressions, puis mots simples. */
    private fun decide(tokens: List<String>): Decision? =
        matchOverride(tokens) ?: matchPhrase(tokens) ?: matchWord(tokens)

    /** 4. Repli : les mots inconnus corrigés, on reclasse. Un résultat exact n'est jamais changé. */
    private fun decideCorrected(tokens: List<String>): Decision? {
        val corrected = tokens.map(::correct)
        if (corrected == tokens) return null
        return decide(corrected)?.copy(match = MatchKind.Fuzzy)
    }

    /**
     * Correction d'un mot inconnu (#98) : mot-clé d'un seul mot, même initiale, à une opération
     * près ; un mot de 5 lettres n'est corrigé que s'il lui manque une lettre. Plusieurs candidats :
     * le premier dans l'ordre alphabétique s'ils ont tous la même catégorie, sinon aucun.
     */
    private fun correct(token: String): String {
        if (!isCorrectable(token)) return token
        val candidates = singleWords.filter { isCandidate(token, it.k) }
        val sameCategory = candidates.isNotEmpty() && candidates.all { it.c == candidates[0].c }
        return if (sameCategory) candidates.minOf { it.k } else token
    }

    private fun isCorrectable(token: String): Boolean =
        token.length >= TYPO_MIN_LENGTH && token !in vocabulary && token.none { it in '0'..'9' }

    private fun isCandidate(
        token: String,
        key: String,
    ): Boolean =
        key[0] == token[0] &&
            (token.length > TYPO_MIN_LENGTH || key.length == token.length + 1) &&
            isOneEditAway(token, key)

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

        /**
         * Mots retirés avant la recherche de mots-clés (#28), sous leur forme normalisée :
         * « biologiques » arrive au singulier. Ils restent dans `normalized`. « AB » est exclu.
         */
        val ORGANIC_WORDS: Set<String> = setOf("bio", "biologique")

        /** Longueur minimale d'un mot corrigé ; à cette longueur, seule une lettre manquante est admise. */
        const val TYPO_MIN_LENGTH = 5

        /**
         * Vrai si [b] s'obtient de [a] par une seule opération : insertion, suppression, substitution
         * ou transposition de deux lettres voisines. Les chaînes sont en ASCII (sortie du normaliseur).
         */
        fun isOneEditAway(
            a: String,
            b: String,
        ): Boolean {
            if (a == b || abs(a.length - b.length) > 1) return false
            var i = 0
            while (i < a.length && i < b.length && a[i] == b[i]) i++
            return when {
                a.length > b.length -> a.substring(i + 1) == b.substring(i)
                a.length < b.length -> a.substring(i) == b.substring(i + 1)
                a.substring(i + 1) == b.substring(i + 1) -> true
                else -> a[i] == b[i + 1] && a[i + 1] == b[i] && a.substring(i + 2) == b.substring(i + 2)
            }
        }

        private fun wordCount(key: String) = key.split(' ').size
    }
}
