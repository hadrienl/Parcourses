package fr.parcourses.core.sorting

import fr.parcourses.core.model.SnapshotEdge
import fr.parcourses.core.model.SnapshotEntry
import fr.parcourses.core.model.SortCategory
import fr.parcourses.core.model.SortInput
import fr.parcourses.core.model.SortItem
import fr.parcourses.core.model.SortOutput
import fr.parcourses.core.model.SortParams
import fr.parcourses.core.model.SortSnapshot
import fr.parcourses.core.model.SortStart
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File

// Lecture des vecteurs de shared/test-vectors/sort/, directement dans le dépôt.

data class SortVector(
    val id: String,
    val input: SortInput,
    val expected: SortOutput,
) {
    override fun toString() = id
}

object SortVectors {
    val dir: File =
        File(requireNotNull(System.getProperty("parcourses.sortVectors")) { "parcourses.sortVectors absent" })

    fun all(): List<SortVector> =
        dir
            .listFiles { f -> f.extension == "json" }
            .orEmpty()
            .sortedBy { it.name }
            .map { parse(Json.parseToJsonElement(it.readText()).jsonObject) }

    fun byId(id: String): SortVector = all().single { it.id == id }

    private fun parse(root: JsonObject): SortVector {
        val input = root.obj("input")
        val expected = root.obj("expected")
        return SortVector(
            id = root.str("id"),
            input =
                SortInput(
                    params = params(input.obj("params")),
                    categories =
                        input.arr("categories").map {
                            SortCategory(it.jsonObject.str("id"), it.jsonObject.num("rank"))
                        },
                    snapshot = input.nullable("snapshot")?.let { snapshot(it.jsonObject) },
                    items = input.arr("items").map { item(it.jsonObject) },
                    start = start(input.obj("start")),
                    previousOrder = input.nullable("previous_order")?.jsonArray?.map { it.jsonPrimitive.content },
                ),
            expected =
                SortOutput(
                    mode = SortOutput.Mode.entries.single { it.wireName == expected.str("mode") },
                    order = expected.arr("order").map { it.jsonPrimitive.content },
                    cost = expected.nullable("cost")?.jsonPrimitive?.long,
                ),
        )
    }

    private fun params(o: JsonObject) =
        SortParams(
            confThresholdQ = o.num("CONF_THRESHOLD_Q"),
            costScale = o.num("COST_SCALE"),
            unknownBase = o.num("UNKNOWN_BASE"),
            catStep = o.num("CAT_STEP"),
            twoOptMaxPasses = o.num("TWO_OPT_MAX_PASSES"),
            reorderMinGainPct = o.num("REORDER_MIN_GAIN_PCT"),
        )

    private fun snapshot(o: JsonObject) =
        SortSnapshot(
            confidenceQ = o.num("confidence_q"),
            entries =
                o
                    .arr(
                        "entries",
                    ).map { SnapshotEntry(it.jsonObject.str("product_id"), it.jsonObject.num("weight_q")) },
            edges =
                o.arr("edges").map {
                    val e = it.jsonObject
                    SnapshotEdge(e.str("a"), e.str("b"), e.num("weight_q"))
                },
        )

    private fun item(o: JsonObject) =
        SortItem(
            id = o.str("id"),
            productId = o.nullable("product_id")?.jsonPrimitive?.content,
            categoryId = o.nullable("category_id")?.jsonPrimitive?.content,
            normalizedName = o.str("normalized_name"),
        )

    // Comme `"entry" in start` dans la référence : la présence de la clé suffit, et elle prime.
    fun start(o: JsonObject): SortStart = if ("entry" in o) SortStart.Entry else SortStart.Product(o.str("product_id"))

    private fun JsonObject.obj(k: String) = getValue(k).jsonObject

    private fun JsonObject.arr(k: String) = getValue(k).jsonArray

    private fun JsonObject.str(k: String) = getValue(k).jsonPrimitive.content

    private fun JsonObject.num(k: String) = getValue(k).jsonPrimitive.long

    private fun JsonObject.nullable(k: String): JsonElement? = get(k)?.takeUnless { it is JsonNull }
}
