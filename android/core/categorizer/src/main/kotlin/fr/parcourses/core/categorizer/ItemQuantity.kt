package fr.parcourses.core.categorizer

/** Raccourcis d'unité du panneau de l'article (#110) : [symbol] est le texte posé dans la quantité. */
enum class QuantityUnit(
    val symbol: String,
) {
    Gram("g"),
    Kilogram("kg"),
    Liter("l"),
    ;

    companion object {
        /** Unité d'un symbole (`g`, `kg`, `l`), casse comprise ; `null` sinon. */
        fun fromSymbol(symbol: String): QuantityUnit? = entries.firstOrNull { it.symbol == symbol }
    }
}

/** Saisie rapide vue par [ItemQuantity.entryMergeTarget] : sa forme normalisée et sa quantité. */
data class QuantityEntry(
    val normalizedName: String,
    val quantity: String?,
)

/** Article de la liste vu par [ItemQuantity.entryMergeTarget]. */
data class QuantityItem(
    val id: String,
    val normalizedName: String,
    val checked: Boolean,
)

/**
 * Quantité d'un article (#110) : fonctions pures, mêmes noms et mêmes résultats qu'iOS (`enum ItemQuantity` du paquet
 * `Domain`), vérifiées par les vecteurs de `shared/test-vectors/quantity/` (référence :
 * `shared/reference/quantity.ts`).
 *
 * La quantité reste un texte libre (« 2 », « 500 g », « 6x33cl », « un peu »). Le − / + agit sur le nombre en tête,
 * s'il y en a un ; le reste (unité, « x33cl ») et l'écart sont gardés tels quels. Chiffres ASCII seulement, calcul en
 * entiers à l'échelle des décimales tapées : jamais de flottant.
 *
 * Les blancs sont ceux de JavaScript (`\s`, `trim()`) : U+0009 à U+000D, U+0020, U+00A0, U+1680, U+2000 à U+200A,
 * U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF. Ni `\s` des regex Java (ASCII seulement) ni `Char.isWhitespace`
 * (qui compte U+001C à U+001F) ne donnent exactement cet ensemble : il est écrit à la main.
 */
@Suppress("TooManyFunctions") // port de la référence : cinq fonctions publiques et leurs aides d'analyse
object ItemQuantity {
    /** Longueur maximale d'une quantité, en points de code (`list_items.quantity`, 50 caractères). */
    const val MAX_QUANTITY_LENGTH = 50

    /** Plus grand nombre de chiffres avant et après la virgule qu'on sait faire varier. */
    private const val MAX_INTEGER_DIGITS = 6
    private const val MAX_FRACTION_DIGITS = 3

    private const val GRAM_STEP = 100L
    private const val CENTILITER_STEP = 10L
    private const val DECIMAL_BASE = 10L

    /**
     * Quantité après un appui sur + ([delta] 1) ou − ([delta] -1). Sans quantité, l'article compte pour un : + donne
     * « 2 ». `null` : bouton inactif (− à 1, quantité sans nombre en tête, nombre trop long).
     */
    @Suppress("ReturnCount") // port de la référence : gardes de sortie anticipée
    fun stepQuantity(
        quantity: String?,
        delta: Int,
    ): String? {
        if (quantity == null) return if (delta > 0) "2" else null
        val parsed = parse(quantity) ?: return null
        val decimals = parsed.fraction.length
        val value = parsed.scaled() + delta * step(parsed.rest) * pow10(decimals)
        if (value <= 0 || value >= pow10(MAX_INTEGER_DIGITS + decimals)) return null
        val number = format(value, decimals, parsed.separator)
        return if (parsed.rest.isEmpty()) number else number + parsed.gap + parsed.rest
    }

    /**
     * Quantité après un appui sur un raccourci d'unité. Sans quantité : une unité de base (« 100 g », « 1 kg »,
     * « 1 l »). Même unité déjà posée (casse ignorée) : elle est retirée. Sinon, le nombre garde sa valeur et son
     * écriture et prend l'unité. `null` : raccourci inactif (quantité sans nombre en tête).
     */
    @Suppress("ReturnCount") // port de la référence : gardes de sortie anticipée
    fun setQuantityUnit(
        quantity: String?,
        unit: QuantityUnit,
    ): String? {
        if (quantity == null) return "${step(unit.symbol)} ${unit.symbol}"
        val parsed = parse(quantity) ?: return null
        val number = parsed.integer + parsed.separator.orEmpty() + parsed.fraction
        return if (parsed.rest.lowercase() == unit.symbol) number else "$number ${unit.symbol}"
    }

    /** Unité des raccourcis portée par la quantité (raccourci sélectionné), sinon `null`. */
    fun quantityUnit(quantity: String?): QuantityUnit? =
        quantity
            ?.let(::parse)
            ?.rest
            ?.lowercase()
            ?.let(QuantityUnit::fromSymbol)

    /**
     * Quantité tapée dans le champ libre : blancs de bord retirés, blancs intérieurs réduits à une espace, coupée à 50
     * points de code (`char_length` de Postgres), sans blanc final. Vide : pas de quantité (`null`).
     */
    fun quantityInput(text: String): String? {
        val collapsed = splitOnBlanks(trimBlanks(text)).joinToString(" ")
        if (collapsed.isEmpty()) return null
        val end =
            if (collapsed.codePointCount(0, collapsed.length) > MAX_QUANTITY_LENGTH) {
                collapsed.offsetByCodePoints(0, MAX_QUANTITY_LENGTH)
            } else {
                collapsed.length
            }
        return collapsed.substring(0, end).trimEnd(::isBlank)
    }

    /**
     * Saisie rapide sur un article déjà dans la liste (#110, point 4) : une saisie qui porte une quantité met à jour le
     * premier article non coché de même forme normalisée, dans l'ordre de la liste ([items] triés par `position`), au
     * lieu d'ajouter un doublon. Renvoie son identifiant ; `null` : la saisie s'ajoute.
     */
    fun entryMergeTarget(
        entry: QuantityEntry,
        items: List<QuantityItem>,
    ): String? {
        if (entry.quantity == null) return null
        return items.firstOrNull { !it.checked && it.normalizedName == entry.normalizedName }?.id
    }

    // region Analyse

    /** Nombre en tête (`integer`, `separator`, `fraction`), écart de blancs, puis le reste. */
    private class ParsedQuantity(
        val integer: String,
        val separator: String?,
        val fraction: String,
        val gap: String,
        val rest: String,
    ) {
        /** Nombre en unités de 10^-décimales. */
        fun scaled(): Long = integer.toLong() * pow10(fraction.length) + (fraction.toLongOrNull() ?: 0L)
    }

    /**
     * Équivalent de `^([0-9]+)(?:([.,])([0-9]+))?(\s*)(.*)$` sur la quantité sans ses blancs de bord. `null` sans
     * nombre en tête, ou avec plus de 6 chiffres avant la virgule ou plus de 3 après.
     */
    @Suppress("ReturnCount") // gardes de sortie anticipée
    private fun parse(quantity: String): ParsedQuantity? {
        val text = trimBlanks(quantity)
        val integerEnd = digitsEnd(text, 0)
        if (integerEnd == 0) return null
        var cursor = integerEnd
        var separator: String? = null
        var fraction = ""
        // La partie décimale n'est prise que si un chiffre suit le séparateur, comme le groupe facultatif de la regex.
        if (cursor < text.length && (text[cursor] == '.' || text[cursor] == ',')) {
            val fractionEnd = digitsEnd(text, cursor + 1)
            if (fractionEnd > cursor + 1) {
                separator = text[cursor].toString()
                fraction = text.substring(cursor + 1, fractionEnd)
                cursor = fractionEnd
            }
        }
        val integer = text.substring(0, integerEnd)
        if (integer.length > MAX_INTEGER_DIGITS || fraction.length > MAX_FRACTION_DIGITS) return null
        var gapEnd = cursor
        while (gapEnd < text.length && isBlank(text[gapEnd])) gapEnd++
        return ParsedQuantity(integer, separator, fraction, text.substring(cursor, gapEnd), text.substring(gapEnd))
    }

    /** Fin de la suite de chiffres ASCII qui commence à [start]. */
    private fun digitsEnd(
        text: String,
        start: Int,
    ): Int {
        var end = start
        while (end < text.length && text[end] in '0'..'9') end++
        return end
    }

    /** Pas du − / + : 100 en grammes et millilitres, 10 en centilitres, 1 sinon. */
    private fun step(rest: String): Long =
        when (rest.lowercase()) {
            "g", "ml" -> GRAM_STEP
            "cl" -> CENTILITER_STEP
            else -> 1L
        }

    private fun format(
        value: Long,
        decimals: Int,
        separator: String?,
    ): String {
        if (decimals == 0) return value.toString()
        val factor = pow10(decimals)
        val fraction = (value % factor).toString().padStart(decimals, '0')
        return "${value / factor}${separator ?: ","}$fraction"
    }

    private fun pow10(exponent: Int): Long {
        var result = 1L
        repeat(exponent) { result *= DECIMAL_BASE }
        return result
    }

    // endregion

    // region Blancs (ceux de JavaScript)

    private fun isBlank(c: Char): Boolean =
        when (c) {
            '\t', '\n', '\u000B', '\u000C', '\r', '\u2028', '\u2029', '\uFEFF' -> true
            else -> Character.getType(c) == Character.SPACE_SEPARATOR.toInt()
        }

    private fun trimBlanks(text: String): String = text.trim(::isBlank)

    /** Découpe aux suites de blancs ; un texte vide donne une seule pièce vide. */
    private fun splitOnBlanks(text: String): List<String> {
        val pieces = mutableListOf<String>()
        val current = StringBuilder()
        var previousBlank = false
        for (c in text) {
            if (isBlank(c)) {
                if (!previousBlank) {
                    pieces += current.toString()
                    current.clear()
                }
                previousBlank = true
            } else {
                current.append(c)
                previousBlank = false
            }
        }
        pieces += current.toString()
        return pieces
    }

    // endregion
}
