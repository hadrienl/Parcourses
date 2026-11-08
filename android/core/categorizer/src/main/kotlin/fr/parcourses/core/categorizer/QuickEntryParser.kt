// Port littéral de `QuickEntryParser` d'iOS (gardes successives).
@file:Suppress("ReturnCount")

package fr.parcourses.core.categorizer

/** Résultat de l'analyse d'une saisie rapide. */
data class QuickEntry(
    /** Quantité en texte libre (`2`, `500 g`), `null` si aucune. */
    val quantity: String?,
    /** Libellé tel que saisi, sans la quantité. */
    val label: String,
)

/**
 * Sépare quantité et libellé dans une saisie rapide (#9 §9) : « 2 laits demi-écrémé ». Port de `QuickEntryParser`
 * d'iOS (`ios/Packages/Domain`), mêmes cas de test.
 *
 * Formes reconnues : `2 lait`, `1,5 kg de pommes`, `500g farine`, `2,5kg pommes`, `6x33cl bière`,
 * `lait x2`, `x2 lait`. Un nombre seul de plus de 3 chiffres reste un libellé (`1664 bière`).
 * Limite connue : `3 Suisses` donne la quantité 3.
 * Une saisie réduite à une quantité reste un libellé : on ne perd jamais ce qui a été tapé.
 */
class QuickEntryParser(
    rules: NormalizationRules,
) {
    private val units: Set<String> = rules.units
    private val normalizer = LabelNormalizer(rules)

    /** Analyseur sur les règles françaises embarquées. */
    constructor() : this(CategoryResources.normalizationRules())

    /** Analyse une saisie. Le libellé est vide seulement si la saisie l'est. */
    fun parse(raw: String): QuickEntry {
        val tokens = raw.split(WHITESPACE).filter { it.isNotEmpty() }
        if (tokens.isEmpty()) return QuickEntry(null, "")
        val trimmed = tokens.joinToString(" ")
        val (quantity, rest) = leadingQuantity(tokens) ?: trailingMultiplier(tokens) ?: return QuickEntry(null, trimmed)
        val label = droppingPartitive(rest).joinToString(" ")
        return if (label.isEmpty()) QuickEntry(null, trimmed) else QuickEntry(quantity, label)
    }

    /** Quantité en tête : nombre et unité, forme collée, ou `x2`. */
    private fun leadingQuantity(tokens: List<String>): Pair<String, List<String>>? {
        val first = tokens.first()
        val rest = tokens.drop(1)
        return when {
            isNumber(first) -> numberAndUnit(first, rest)
            isGluedQuantity(first) -> first to rest
            isMultiplier(first) -> first.drop(1) to rest
            else -> null
        }
    }

    private fun numberAndUnit(
        first: String,
        rest: List<String>,
    ): Pair<String, List<String>>? {
        val next = rest.firstOrNull()
        if (next != null && normalizer.normalizeText(next) in units) {
            // « 2 x lait » : le « x » n'apporte rien à la quantité affichée.
            val quantity = if (normalizer.normalizeText(next) == "x") first else "$first $next"
            return quantity to rest.drop(1)
        }
        // Au-delà de 3 chiffres, un nombre seul est un nom (« 1664 bière »).
        return if (first.count(::isAsciiDigit) <= MAX_BARE_DIGITS) first to rest else null
    }

    /** `lait x2`. */
    private fun trailingMultiplier(tokens: List<String>): Pair<String, List<String>>? {
        val last = tokens.last()
        if (tokens.size <= 1 || !isMultiplier(last)) return null
        return last.drop(1) to tokens.dropLast(1)
    }

    /** Retire « de », « d' » ou « d’ » placé juste après la quantité. */
    private fun droppingPartitive(tokens: List<String>): List<String> {
        val first = tokens.firstOrNull() ?: return tokens
        val lowered = first.lowercase()
        return when {
            lowered == "de" || lowered == "d'" || lowered == "d’" -> tokens.drop(1)
            lowered.startsWith("d'") || lowered.startsWith("d’") -> listOf(first.drop(2)) + tokens.drop(1)
            else -> tokens
        }
    }

    /** `2`, `1,5`, `0.5`. */
    private fun isNumber(token: String): Boolean {
        val parts = token.split('.', ',')
        return parts.size <= 2 && parts.all { it.isNotEmpty() && it.all(::isAsciiDigit) }
    }

    /** `x2`. */
    private fun isMultiplier(token: String): Boolean {
        val lowered = token.lowercase()
        return lowered.startsWith("x") && lowered.length > 1 && lowered.drop(1).all(::isAsciiDigit)
    }

    /** `500g`, `2kg`, `2,5kg`, `1.5l`, `2x`, `6x33cl`. */
    private fun isGluedQuantity(token: String): Boolean {
        val lowered = token.lowercase()
        val number = lowered.takeWhile { isAsciiDigit(it) || it == ',' || it == '.' }
        val suffix = lowered.drop(number.length)
        if (isNumber(number) && suffix in units) return true
        val digits = lowered.takeWhile(::isAsciiDigit)
        if (digits.isEmpty() || digits.length != number.length || suffix.firstOrNull() != 'x') return false
        val afterX = suffix.drop(1)
        val innerDigits = afterX.takeWhile(::isAsciiDigit)
        if (innerDigits.isEmpty()) return false
        return innerDigits.length == afterX.length || afterX.drop(innerDigits.length) in units
    }

    private fun isAsciiDigit(c: Char): Boolean = c in '0'..'9'

    private companion object {
        const val MAX_BARE_DIGITS = 3
        val WHITESPACE = Regex("\\s+")
    }
}
