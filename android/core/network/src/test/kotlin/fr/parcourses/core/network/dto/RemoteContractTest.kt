@file:Suppress("ktlint:standard:max-line-length")

package fr.parcourses.core.network.dto

import fr.parcourses.core.network.RemoteJson
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * Les DTO sont confrontés à `shared/contract/tables.json` (régénéré depuis le schéma, #8) et aux
 * `grant` / `create function` des migrations. Équivalent d'`ios/ParcoursesTests/RemoteContractTests.swift`.
 */
class RemoteContractTest {
    private val root = File(checkNotNull(System.getProperty("parcourses.repoRoot")))
    private val contract: Map<String, Set<String>> by lazy {
        val json = RemoteJson.parseToJsonElement(File(root, "shared/contract/tables.json").readText()).jsonObject
        json.mapValues { (_, columns) ->
            (columns as kotlinx.serialization.json.JsonArray).map { it.jsonPrimitive.content }.toSet()
        }
    }
    private val migrations: String by lazy {
        File(root, "supabase/migrations")
            .listFiles { f -> f.extension == "sql" }
            .orEmpty()
            .sortedBy { it.name }
            .joinToString("\n") { it.readText() }
    }

    private val readSpecs: List<TableSpec<*>> =
        listOf(ListRow.spec, ListItemRow.spec, VisitRow.spec, CheckRow.spec, CategoryRow.spec, ProductRow.spec)

    /**
     * Tables que l'app ne lit pas directement : magasins par RPC, graphe écrit et servi par le serveur. `profiles` et
     * `list_item_tombstones` (#87, lot 87.1) : lues à partir du lot Android 87.5.
     */
    private val tablesWithoutDto =
        setOf(
            "stores",
            "store_edges",
            "store_entries",
            "store_stats",
            "store_graph_snapshots",
            "profiles",
            "list_item_tombstones",
        )

    /**
     * Colonnes internes au calcul du graphe (#11) et au catalogue (#69), que l'app ne lit pas. Toute autre colonne doit
     * avoir son DTO. `products.published_at` : la RLS ne renvoie que des produits publiés.
     * `updated_by` (#87, lot 87.1) : lue à partir du lot Android 87.5.
     */
    private val serverOnlyColumns =
        mapOf(
            "lists" to setOf("updated_by"),
            "list_items" to setOf("updated_by"),
            "products" to setOf("published_at"),
            "visits" to
                setOf(
                    "auto_closed",
                    "learn_outcome",
                    "learn_weight",
                    "next_attempt_at",
                    "process_attempts",
                    "process_error",
                    "processed_algo_version",
                ),
        )

    /** Colonnes accordées à `authenticated` : [verb] vaut `insert` ou `update`, lues dans les migrations. */
    private fun granted(
        verb: String,
        table: String,
    ): Set<String> =
        Regex("""grant\s+$verb\s*\(([^)]*)\)\s+on\s+public\.$table\b""", RegexOption.IGNORE_CASE)
            .findAll(migrations)
            .flatMap { it.groupValues[1].split(",").map(String::trim) }
            .toSet()

    private fun keys(json: JsonObject) = json.keys

    private val id = Uuid.parse("11111111-1111-1111-1111-111111111111")
    private val now = Instant.parse("2026-10-31T10:00:00Z")

    @Test
    fun readDtosCoverExactlyTheColumnsOfTheirTable() {
        for (spec in readSpecs) {
            val columns = contract[spec.table] ?: error("table ${spec.table} absente du contrat")
            val expected = columns - serverOnlyColumns[spec.table].orEmpty()
            assertEquals(spec.table, expected, spec.columns.toSet())
        }
    }

    @Test
    fun everyTableIsAccountedFor() {
        val covered = readSpecs.map { it.table }.toSet() + tablesWithoutDto
        assertEquals(contract.keys, covered)
    }

    @Test
    fun writeDtosEncodeExactlyTheirColumnsAndOnlyGrantedOnes() {
        val samples: List<Triple<TableSpec<*>, Set<String>, JsonObject>> =
            listOf(
                Triple(ListUpsert.spec, granted("insert", "lists"), encode(ListUpsert.spec, ListUpsert(id, "n"))),
                Triple(
                    ListItemUpsert.spec,
                    granted("insert", "list_items"),
                    encode(ListItemUpsert.spec, ListItemUpsert(id, id, null, "l", null, null)),
                ),
                Triple(
                    VisitInsert.spec,
                    granted("insert", "visits"),
                    encode(VisitInsert.spec, VisitInsert(id, id, id, false, now)),
                ),
                Triple(
                    CheckInsert.spec,
                    granted("insert", "checks"),
                    encode(CheckInsert.spec, CheckInsert.forProduct(id, id, id, now)),
                ),
            )
        for ((spec, grants, json) in samples) {
            assertTrue("aucun grant lu pour ${spec.table}", grants.isNotEmpty())
            assertEquals(spec.table, grants, keys(json))
            assertEquals(spec.table, spec.columns.toSet(), keys(json))
            assertTrue(spec.table, contract.getValue(spec.table).containsAll(keys(json)))
        }
    }

    @Test
    fun patchesEncodeOnlyColumnsGrantedForUpdate() {
        fun <T> keysOf(
            serializer: kotlinx.serialization.KSerializer<T>,
            value: T,
        ) = RemoteJson.encodeToJsonElement(serializer, value).jsonObject.keys
        assertEquals(granted("update", "lists"), keysOf(ListPatch.serializer(), ListPatch("n")))
        assertEquals(
            granted("update", "list_items"),
            keysOf(ListItemPatch.serializer(), ListItemPatch(id, null, "l", null, null)),
        )
        assertEquals(granted("update", "visits"), keysOf(VisitClose.serializer(), VisitClose(now)))
    }

    @Test
    fun checkEncodesExplicitNullsSoBatchesAreUniform() {
        val check = CheckInsert.forCategory(id, id, 3, now)
        val json = encode(CheckInsert.spec, check)
        assertEquals(JsonNull, json["product_id"])
        assertEquals(3, json["category_id"]!!.jsonPrimitive.intOrNull)
    }

    @Test
    fun rpcParametersMatchTheMigrations() {
        val functions =
            mapOf(
                "nearby_stores" to listOf("lat", "lng", "radius_m", "max_results"),
                "search_stores" to listOf("q", "max_results"),
                "resolve_products" to listOf("p_items"),
                "store_graph_snapshot" to listOf("p_store_id", "p_known_version"),
            )
        for ((name, parameters) in functions) {
            // Dernière définition (les migrations sont triées par date).
            val definition =
                Regex("""create\s+or\s+replace\s+function\s+public\.$name\s*\(([^)]*)\)""", RegexOption.IGNORE_CASE)
                    .findAll(migrations)
                    .last()
                    .groupValues[1]
            val declared = definition.split(",").map { it.trim().substringBefore(" ") }
            assertEquals(name, parameters, declared)
        }
    }

    @Test
    fun rpcResultColumnsMatchTheRowDtos() {
        fun returned(name: String): List<String> {
            val body =
                Regex(
                    """function\s+public\.$name\s*\([^)]*\)\s*returns\s+table\s*\(([^)]*)\)""",
                    RegexOption.IGNORE_CASE,
                ).findAll(migrations)
                    .last()
                    .groupValues[1]
            return body.split(",").map { it.trim().substringBefore(" ") }
        }

        fun columns(serializer: kotlinx.serialization.KSerializer<*>) =
            serializer.descriptor.let { d -> (0 until d.elementsCount).map(d::getElementName) }
        assertEquals(returned("nearby_stores"), columns(NearbyStoreRow.serializer()))
        assertEquals(returned("search_stores"), columns(StoreSearchRow.serializer()))
        assertEquals(returned("resolve_products").toSet(), columns(ResolvedProductRow.serializer()).toSet())
    }

    private fun <T : Any> encode(
        spec: TableSpec<T>,
        value: Any,
    ): JsonObject {
        @Suppress("UNCHECKED_CAST")
        return RemoteJson.encodeToJsonElement(spec.serializer, value as T).jsonObject
    }

    // JSON figés, dans la forme renvoyée par PostgREST (microsecondes et décalage horaire).
    private val u = "11111111-1111-1111-1111-111111111111"
    private val d = "2026-10-31T10:00:00.123456+00:00"

    private inline fun <reified T> decode(
        serializer: kotlinx.serialization.KSerializer<T>,
        json: String,
    ): T = RemoteJson.decodeFromString(serializer, json)

    @Test
    fun rowsDecodeFrozenPostgrestJson() {
        val list =
            decode(
                ListRow.serializer(),
                """{"id":"$u","owner_id":"$u","name":"C","created_at":"$d","updated_at":"$d"}""",
            )
        assertEquals("C", list.name)
        assertEquals(Instant.parse("2026-10-31T10:00:00.123456Z"), list.createdAt)
        val item =
            decode(
                ListItemRow.serializer(),
                """{"id":"$u","list_id":"$u","product_id":null,"label":"Lait","quantity":null,"checked_at":"$d","created_at":"$d","updated_at":"$d"}""",
            )
        assertTrue(item.checkedAt != null && item.quantity == null)
        val visit =
            decode(
                VisitRow.serializer(),
                """{"id":"$u","user_id":"$u","store_id":"$u","list_id":null,"list_was_sorted":true,"started_at":"$d","ended_at":null,"processed_at":null}""",
            )
        assertTrue(visit.listWasSorted && visit.endedAt == null)
        val check =
            decode(
                CheckRow.serializer(),
                """{"id":"$u","visit_id":"$u","product_id":null,"category_id":4,"checked_at":"$d","ignored":false}""",
            )
        assertEquals(4.toShort(), check.categoryId)
        val category =
            decode(CategoryRow.serializer(), """{"id":4,"slug":"dairy","name":"Crèmerie","default_rank":70}""")
        assertEquals(70.toShort(), category.defaultRank)
        val product =
            decode(
                ProductRow.serializer(),
                """{"id":"$u","name":"Lait","normalized_name":"lait","category_id":4,"off_code":null,"created_at":"$d"}""",
            )
        assertEquals("lait", product.normalizedName)
        val store =
            decode(
                ListSerializer(NearbyStoreRow.serializer()),
                """[{"id":"$u","name":"S","chain":null,"address":null,"distance_m":12.5,"organic_aisle":false}]""",
            ).single()
        assertEquals(12.5, store.distanceM, 0.0)
        val found =
            decode(
                StoreSearchRow.serializer(),
                """{"id":"$u","name":"S","chain":null,"address":"A","organic_aisle":false}""",
            )
        assertEquals("A", found.address)
    }

    @Test
    fun optionalOrganicAisleColumnDoesNotBreakOlderServers() {
        val store = decode(StoreSearchRow.serializer(), """{"id":"$u","name":"S","chain":null,"address":null}""")
        assertNull(store.organicAisle)
        val nearby = decode(NearbyStoreRow.serializer(), """{"id":"$u","name":"S","distance_m":1}""")
        assertNull(nearby.organicAisle)
    }

    @Test
    fun resolvedProductsKeepNullIdsAndRequestsUseSnakeCase() {
        val rows =
            decode(
                ListSerializer(ResolvedProductRow.serializer()),
                """[{"normalized_name":"lait","id":"$u","name":"Lait","category_slug":"dairy"},{"normalized_name":"x","id":null,"name":null,"category_slug":null}]""",
            )
        assertEquals(Uuid.parse(u), rows[0].id)
        assertNull(rows[1].id)
        val request =
            RemoteJson
                .encodeToJsonElement(
                    ProductResolutionRequest.serializer(),
                    ProductResolutionRequest("Lait", null),
                ).jsonObject
        assertEquals(setOf("name", "category_slug"), request.keys)
        assertEquals(JsonNull, request["category_slug"])
    }

    @Test
    fun snapshotResponsesAreTold() {
        assertEquals(GraphSnapshotResponse.Unchanged, GraphSnapshotResponse.parse("null"))
        assertEquals(GraphSnapshotResponse.Unchanged, GraphSnapshotResponse.parse(""))
        assertEquals(GraphSnapshotResponse.None, GraphSnapshotResponse.parse("""{"none":true}"""))
        val payload = """{"format_version":1,"entries":[]}"""
        assertEquals(GraphSnapshotResponse.Payload(payload), GraphSnapshotResponse.parse(payload))
    }
}
