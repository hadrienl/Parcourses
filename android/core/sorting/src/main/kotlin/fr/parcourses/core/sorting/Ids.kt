package fr.parcourses.core.sorting

// Identifiants ASCII `[0-9a-z-]+` (shared/README.md, règle 2) : déjà en minuscules, donc
// l'ordre des octets UTF-8 est l'ordre des `Char`. `normalized_name`, lui, peut contenir
// n'importe quel caractère et se compare sur ses octets UTF-8, jamais selon la locale.

private val ID_PATTERN = Regex("^[0-9a-z-]+$")

/** Vrai si [id] respecte le format imposé aux identifiants. */
internal fun isValidId(id: String): Boolean = ID_PATTERN.matches(id)

/** Compare deux chaînes octet par octet (non signés) en UTF-8. */
internal fun compareBytes(
    a: String,
    b: String,
): Int {
    val x = a.encodeToByteArray()
    val y = b.encodeToByteArray()
    val n = minOf(x.size, y.size)
    for (i in 0 until n) {
        val c = (x[i].toInt() and BYTE_MASK).compareTo(y[i].toInt() and BYTE_MASK)
        if (c != 0) return c
    }
    return x.size.compareTo(y.size)
}

/** Ordre des identifiants : octets ASCII. */
internal fun compareIds(
    a: String,
    b: String,
): Int = compareBytes(a, b)

private const val BYTE_MASK = 0xFF
