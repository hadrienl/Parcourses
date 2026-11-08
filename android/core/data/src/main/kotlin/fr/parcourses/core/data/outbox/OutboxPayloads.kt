package fr.parcourses.core.data.outbox

import fr.parcourses.core.database.entity.CheckEntity
import fr.parcourses.core.network.dto.CheckUpload
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Date ISO 8601 en UTC : lisible dans la base, sans perte de précision. */
object IsoInstantSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("fr.parcourses.IsoInstant", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): Instant = Instant.parse(decoder.decodeString())

    override fun serialize(
        encoder: Encoder,
        value: Instant,
    ) = encoder.encodeString(value.toString())
}

/**
 * Charges utiles de la file. Le codage reste local à l'appareil : aucune contrainte de format réseau.
 * Les lignes qui partent telles quelles au serveur (`ListUpsert`, `ListItemUpsert`, `VisitInsert`) réutilisent
 * les DTO de `:core:network`.
 */
object OutboxCoding {
    private val json =
        Json {
            ignoreUnknownKeys = true
            explicitNulls = true
            encodeDefaults = true
        }

    fun <T> encode(
        serializer: KSerializer<T>,
        value: T,
    ): ByteArray = json.encodeToString(serializer, value).encodeToByteArray()

    fun <T> decode(
        serializer: KSerializer<T>,
        bytes: ByteArray,
    ): T = json.decodeFromString(serializer, bytes.decodeToString())
}

/** Identifiant en texte minuscule, comme dans la base locale. */
internal fun Uuid.asId(): String = toString()

internal fun String.asUuid(): Uuid = Uuid.parse(this)

@Serializable
data class ItemDeletionPayload(
    val listId: String,
)

@Serializable
data class VisitClosePayload(
    val visitId: String,
    @Serializable(with = IsoInstantSerializer::class) val endedAt: Instant,
)

/** Coche en file : `productId` xor `categoryId`, comme le modèle local. */
@Serializable
data class CheckPayload(
    val id: String,
    val visitId: String,
    val productId: String?,
    val categoryId: String?,
    @Serializable(with = IsoInstantSerializer::class) val checkedAt: Instant,
) {
    constructor(check: CheckEntity) : this(check.id, check.visitId, check.productId, check.categoryId, check.checkedAt)

    fun with(checkedAt: Instant): CheckPayload = copy(checkedAt = checkedAt)

    /** La coche désigne un produit, plus sa catégorie. L'horodatage déjà corrigé (`ServerClock`) est gardé. */
    fun withProduct(productId: String): CheckPayload = copy(productId = productId, categoryId = null)

    /** `null` si la coche ne désigne rien : elle ne pourra jamais être envoyée. */
    fun upload(): CheckUpload? =
        when {
            productId != null -> {
                CheckUpload(
                    id.asUuid(),
                    visitId.asUuid(),
                    CheckUpload.Target.Product(productId.asUuid()),
                    checkedAt,
                )
            }

            categoryId != null -> {
                CheckUpload(
                    id.asUuid(),
                    visitId.asUuid(),
                    CheckUpload.Target.Category(categoryId),
                    checkedAt,
                )
            }

            else -> {
                null
            }
        }
}
