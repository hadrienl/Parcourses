package fr.parcourses.core.network.dto

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** UUID en texte minuscule, comme PostgREST et comme la règle de comparaison de #5. */
internal object UuidSerializer : KSerializer<Uuid> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("fr.parcourses.Uuid", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): Uuid = Uuid.parse(decoder.decodeString())

    override fun serialize(encoder: Encoder, value: Uuid) = encoder.encodeString(value.toString())
}

/**
 * Dates ISO 8601. PostgREST renvoie des microsecondes et un décalage (`2026-10-31T10:00:00.123456+00:00`) ;
 * l'app envoie toujours de l'UTC (`Z`).
 */
internal object InstantSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("fr.parcourses.Instant", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): Instant = Instant.parse(decoder.decodeString())

    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(value.toString())
}
