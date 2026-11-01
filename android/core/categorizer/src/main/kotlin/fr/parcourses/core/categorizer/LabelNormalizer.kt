package fr.parcourses.core.categorizer

import java.text.Normalizer
import java.util.Locale

// Échappements obligatoires (shared/README.md) : des caractères combinants littéraux seraient invisibles.
private val DIACRITICS = Regex("[\\u0300-\\u036f]")
private val NON_ALPHANUMERIC = Regex("[^a-z0-9]+")
private val COMPOSED_QUANTITY = Regex("^[0-9]*x[0-9]+[a-z]*$")
private val NUMBER_WITH_SUFFIX = Regex("^[0-9]+([a-z]*)$")
private val SILENT_X_SUFFIXES = listOf("eux", "aux", "oux")
private const val PLURAL_AL_SUFFIX_LENGTH = 3
private const val MIN_LENGTH_TO_DROP_S = 4

/** Normalisation des libellés (#7 §2.1), identique à `shared/reference/normalize.ts`. */
class LabelNormalizer(
    private val rules: NormalizationRules,
) {
    /** Normaliseur sur les règles françaises embarquées. */
    constructor() : this(CategoryResources.normalizationRules())

    // Ligatures triées par octets UTF-8, pour un résultat indépendant de l'ordre de la table.
    private val ligatures: List<Pair<String, String>> =
        rules.ligatures.toList().sortedWith { a, b -> compareUtf8(a.first, b.first) }

    /**
     * Forme « texte » : minuscules, ligatures, sans diacritiques, `[a-z0-9]` séparés par une espace.
     * C'est le `normalizedName` utilisé par le tri de repli.
     */
    fun normalizeText(raw: String): String {
        // Locale.ROOT : le « I » reste « i » sur un appareil en turc.
        // Le remplacement est littéral et précède NFD : « œ » suivi d'un accent combinant est bien remplacé.
        val withoutLigatures =
            ligatures.fold(raw.lowercase(Locale.ROOT)) { text, (from, to) -> text.replace(from, to) }
        return Normalizer
            .normalize(withoutLigatures, Normalizer.Form.NFD)
            .replace(DIACRITICS, "")
            .replace(NON_ALPHANUMERIC, " ")
            .trim()
    }

    /**
     * Forme de comparaison avec le dictionnaire : forme texte sans quantités, unités
     * ni mots vides, chaque mot au singulier.
     */
    fun normalize(raw: String): String =
        normalizeText(raw)
            .split(' ')
            .filter { it.isNotEmpty() && it !in rules.stopwords && !isQuantity(it) }
            .joinToString(" ", transform = ::singularize)

    /** Singulier par règles simples ; les exceptions sont prioritaires. */
    fun singularize(token: String): String =
        when {
            token in rules.pluralExceptions -> token
            token in rules.pluralAl -> token.dropLast(PLURAL_AL_SUFFIX_LENGTH) + "al"
            SILENT_X_SUFFIXES.any(token::endsWith) -> token.dropLast(1)
            token.endsWith("s") && token.length >= MIN_LENGTH_TO_DROP_S -> token.dropLast(1)
            else -> token
        }

    /** Vrai pour un nombre, une unité, un nombre collé à une unité (`2kg`) ou `x6`, `6x33cl`. */
    private fun isQuantity(token: String): Boolean =
        token in rules.units ||
            COMPOSED_QUANTITY.matches(token) ||
            NUMBER_WITH_SUFFIX
                .matchEntire(token)
                ?.groupValues
                ?.get(1)
                ?.let { it.isEmpty() || it in rules.units } ==
            true
}

/** Comparaison sur les octets UTF-8 non signés, sans dépendre de la locale. */
private fun compareUtf8(
    a: String,
    b: String,
): Int {
    val x = a.encodeToByteArray().map { it.toUByte() }
    val y = b.encodeToByteArray().map { it.toUByte() }
    val firstDifference = x.indices.firstOrNull { it < y.size && x[it] != y[it] }
    return firstDifference?.let { x[it].compareTo(y[it]) } ?: x.size.compareTo(y.size)
}
