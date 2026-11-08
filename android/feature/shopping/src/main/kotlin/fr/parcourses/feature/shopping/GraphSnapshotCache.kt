package fr.parcourses.feature.shopping

import fr.parcourses.core.data.repository.GraphRepository
import fr.parcourses.core.model.SnapshotEdge
import fr.parcourses.core.model.SnapshotEntry
import fr.parcourses.core.model.SortParams
import fr.parcourses.core.model.SortSnapshot
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.dto.GraphSnapshotResponse
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.time.Clock
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Instantané décodé : ce que le tri consomme et ce que l'écran affiche. */
data class LoadedSnapshot(
    val version: Long,
    val params: SortParams,
    val snapshot: SortSnapshot,
)

@Serializable
private data class ParamsJson(
    @SerialName("CONF_THRESHOLD_Q") val confThresholdQ: Long,
    @SerialName("COST_SCALE") val costScale: Long,
    @SerialName("UNKNOWN_BASE") val unknownBase: Long,
    @SerialName("CAT_STEP") val catStep: Long,
    @SerialName("TWO_OPT_MAX_PASSES") val twoOptMaxPasses: Long,
    @SerialName("REORDER_MIN_GAIN_PCT") val reorderMinGainPct: Long,
)

@Serializable
private data class EntryJson(
    @SerialName("product_id") val productId: String,
    @SerialName("weight_q") val weightQ: Long,
)

@Serializable
private data class EdgeJson(
    val a: String,
    val b: String,
    @SerialName("weight_q") val weightQ: Long,
)

/** Contenu de `store_graph_snapshot` (#11 §7). Tout autre champ du JSON est ignoré. */
@Serializable
private data class PayloadJson(
    @SerialName("format_version") val formatVersion: Int,
    @SerialName("snapshot_version") val snapshotVersion: Long,
    @SerialName("params_version") val paramsVersion: Long,
    val params: ParamsJson,
    @SerialName("confidence_q") val confidenceQ: Long,
    val entries: List<EntryJson>,
    val edges: List<EdgeJson>,
)

/** Un instantané décodé avec les versions que le cache enregistre. */
internal class DecodedPayload(
    val snapshotVersion: Long,
    val paramsVersion: Long,
    val confidenceQ: Long,
    val loaded: LoadedSnapshot,
)

internal object GraphPayload {
    private const val SUPPORTED_FORMAT = 1
    private val json = Json { ignoreUnknownKeys = true }

    /** `null` si le format est inconnu ou le JSON illisible : on trie alors sans graphe plutôt que de deviner. */
    fun decode(bytes: ByteArray): DecodedPayload? =
        runCatching { json.decodeFromString<PayloadJson>(bytes.decodeToString()) }
            .getOrNull()
            ?.takeIf { it.formatVersion == SUPPORTED_FORMAT }
            ?.let { p ->
                val params =
                    SortParams(
                        confThresholdQ = p.params.confThresholdQ,
                        costScale = p.params.costScale,
                        unknownBase = p.params.unknownBase,
                        catStep = p.params.catStep,
                        twoOptMaxPasses = p.params.twoOptMaxPasses,
                        reorderMinGainPct = p.params.reorderMinGainPct,
                    )
                val snapshot =
                    SortSnapshot(
                        confidenceQ = p.confidenceQ,
                        entries = p.entries.map { SnapshotEntry(it.productId, it.weightQ) },
                        edges = p.edges.map { SnapshotEdge(it.a, it.b, it.weightQ) },
                    )
                DecodedPayload(
                    p.snapshotVersion,
                    p.paramsVersion,
                    p.confidenceQ,
                    LoadedSnapshot(p.snapshotVersion, params, snapshot),
                )
            }
}

/** Cache local de l'instantané d'un magasin. Sans réseau ni session, le cache suffit. */
class GraphSnapshotCache(
    private val graphs: GraphRepository,
    val gateway: RemoteGateway?,
    private val now: () -> Instant = { Clock.System.now() },
) {
    suspend fun cached(storeId: String): LoadedSnapshot? =
        graphs.snapshot(storeId)?.let { GraphPayload.decode(it.payload)?.loaded }

    /**
     * Interroge le serveur et enregistre une nouvelle version. `null` si rien de neuf. Un instantané illisible ne
     * donne pas sa version : il sera redemandé en entier.
     */
    suspend fun refresh(storeId: String): LoadedSnapshot? {
        val remote = gateway ?: return null
        val known = cached(storeId)?.version
        val response = remote.graphSnapshot(Uuid.parse(storeId), known)
        val raw = (response as? GraphSnapshotResponse.Payload)?.json?.encodeToByteArray()
        return raw?.let { bytes ->
            GraphPayload.decode(bytes)?.let { decoded ->
                graphs.saveSnapshot(
                    storeId = storeId,
                    snapshotVersion = decoded.snapshotVersion,
                    paramsVersion = decoded.paramsVersion,
                    confidenceQ = decoded.confidenceQ,
                    payload = bytes,
                    at = now(),
                )
                decoded.loaded
            }
        }
    }
}
