package fr.parcourses.core.data

import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.categorizer.QuickEntryParser

/** Saisie rapide analysée : quantité, libellé, forme normalisée et catégorie. */
data class AnalyzedEntry(
    val quantity: String?,
    val label: String,
    val normalizedName: String,
    val categoryId: String,
    val organic: Boolean,
)

/** Réunit l'analyseur de saisie et le classifieur (`EntryAnalyzer` d'iOS). Immuable : partagé entre threads. */
class EntryAnalyzer(
    private val parser: QuickEntryParser = QuickEntryParser(),
    private val classifier: CategoryClassifier = CategoryClassifier(),
) {
    fun analyze(raw: String): AnalyzedEntry {
        val entry = parser.parse(raw)
        val classification = classifier.classify(entry.label)
        return AnalyzedEntry(
            quantity = entry.quantity,
            label = entry.label,
            normalizedName = classification.normalized,
            categoryId = classification.categoryId,
            organic = classification.organic,
        )
    }

    /** Résultat du classifieur pour un libellé déjà séparé de sa quantité. */
    fun classify(label: String): Pair<String, Boolean> = classifier.classify(label).let { it.categoryId to it.organic }

    /** Formes à chercher pour l'autocomplétion : le texte brut (« lai ») et le singulier (« laits » → « lait »). */
    fun searchForms(label: String): List<String> =
        listOf(classifier.normalizer.normalizeText(label), classifier.normalizer.normalize(label))
            .filter { it.isNotEmpty() }
            .distinct()
            .sorted()
}
