package fr.parcourses.core.categorizer

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/** Une catégorie de rayon (#7 §1). `rank` ne sert qu'à ordonner. */
data class ItemCategory(
    /** Identifiant stable, ASCII `[0-9a-z-]` (`produce`, `savory-grocery`…). */
    val id: String,
    /** Clé d'ordre générique du rayon (10, 20… 999 pour `other`). */
    val rank: Long,
    /** Libellé français affiché. */
    val labelFr: String,
)

/** Règles de normalisation (`normalization.json`). */
data class NormalizationRules(
    val ligatures: Map<String, String>,
    val units: Set<String>,
    val stopwords: Set<String>,
    val pluralAl: Set<String>,
    val pluralExceptions: Set<String>,
)

/** Entrée du dictionnaire : clé déjà normalisée, catégorie, marque éventuelle. */
data class KeywordEntry(
    /** Forme normalisée (`normalize(k) == k`). */
    val k: String,
    /** Identifiant de catégorie. */
    val c: String,
    /** Vrai pour une marque, qui ne l'emporte jamais sur un nom de produit. */
    val brand: Boolean? = null,
)

/** Dictionnaire de mots-clés (`keywords.fr.json`). */
data class KeywordDictionary(
    val version: Int,
    val locale: String,
    val keywords: List<KeywordEntry>,
    /** Modificateurs prioritaires (« surgelé »…). */
    val overrides: List<KeywordEntry>,
)

/** Erreurs de chargement des ressources embarquées. */
sealed class CategoryResourceError(
    message: String,
) : IllegalStateException(message) {
    class MissingResource(
        val name: String,
    ) : CategoryResourceError("Ressource absente : $name")
}

/** Accès aux fichiers de `shared/categories/` embarqués dans le module. */
object CategoryResources {
    // Chemin absolu dans le chargeur de classes : il ne dépend pas d'un renommage de paquet par R8.
    private const val RESOURCE_DIR = "fr/parcourses/core/categorizer"

    // Lecture et décodage une seule fois par processus, à la première demande.
    private val cachedCategories by lazy {
        read("categories")
            .array("categories")
            .map { element ->
                val o = element.jsonObject
                ItemCategory(o.string("id"), o.getValue("rank").jsonPrimitive.long, o.string("label_fr"))
            }
            // Identifiants ASCII : l'ordre UTF-16 de compareBy est aussi celui des octets.
            .sortedWith(compareBy({ it.rank }, { it.id }))
    }
    private val cachedRules by lazy {
        val o = read("normalization")
        NormalizationRules(
            ligatures = o.getValue("ligatures").jsonObject.mapValues { it.value.jsonPrimitive.content },
            units = o.stringSet("units"),
            stopwords = o.stringSet("stopwords"),
            pluralAl = o.stringSet("plural_al"),
            pluralExceptions = o.stringSet("plural_exceptions"),
        )
    }
    private val cachedKeywords by lazy {
        val o = read("keywords.fr")
        KeywordDictionary(
            version = o.getValue("version").jsonPrimitive.int,
            locale = o.string("locale"),
            keywords = o.array("keywords").map(::keywordEntry),
            overrides = o.array("overrides").map(::keywordEntry),
        )
    }

    /** Les 20 catégories, triées par `(rank, id)`. Lues une seule fois, puis servies depuis le cache. */
    fun categories(): List<ItemCategory> = cachedCategories

    /** Règles de normalisation françaises. Lues une seule fois, puis servies depuis le cache. */
    fun normalizationRules(): NormalizationRules = cachedRules

    /** Dictionnaire de mots-clés français. Lu une seule fois, puis servi depuis le cache. */
    fun keywordDictionary(): KeywordDictionary = cachedKeywords

    private fun read(name: String): JsonObject {
        val path = "$RESOURCE_DIR/$name.json"
        val stream =
            CategoryResources::class.java.classLoader?.getResourceAsStream(path)
                ?: throw CategoryResourceError.MissingResource(name)
        return Json.parseToJsonElement(stream.use { it.readBytes().decodeToString() }).jsonObject
    }

    private fun keywordEntry(element: JsonElement): KeywordEntry {
        val o = element.jsonObject
        return KeywordEntry(o.string("k"), o.string("c"), o["brand"]?.jsonPrimitive?.boolean)
    }

    private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.content

    private fun JsonObject.array(key: String) = getValue(key).jsonArray

    private fun JsonObject.stringSet(key: String) = array(key).map { it.jsonPrimitive.content }.toSet()
}
