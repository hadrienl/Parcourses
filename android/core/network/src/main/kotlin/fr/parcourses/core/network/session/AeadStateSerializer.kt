package fr.parcourses.core.network.session

import androidx.datastore.core.CorruptionException
import androidx.datastore.core.Serializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import java.io.InputStream
import java.io.OutputStream
import java.security.GeneralSecurityException

/**
 * Sérialiseur DataStore : JSON chiffré en AES-256-GCM (Tink). Le fichier ne contient jamais de texte clair.
 *
 * Si le Keystore est indisponible, [AeadSource.get] lève [SecureStorageUnavailableException] et le fichier n'est
 * **pas** remplacé. Seul un fichier qui ne se déchiffre pas avec une clé disponible est déclaré corrompu
 * ([CorruptionException]). Une clé définitivement perdue est recréée par [AeadSource] ; le fichier devient alors
 * illisible et est remplacé par un état vide.
 */
internal class AeadStateSerializer(
    private val aead: AeadSource,
    private val json: Json = Json { ignoreUnknownKeys = true },
) : Serializer<SessionHolder> {
    override val defaultValue: SessionHolder = SessionHolder()

    override suspend fun readFrom(input: InputStream): SessionHolder {
        val bytes = input.readBytes()
        if (bytes.isEmpty()) return defaultValue
        val cipher = aead.get()
        return try {
            json.decodeFromString(SessionHolder.serializer(), cipher.decrypt(bytes, ASSOCIATED_DATA).decodeToString())
        } catch (e: GeneralSecurityException) {
            throw CorruptionException("Session illisible avec la clé courante", e)
        } catch (e: SerializationException) {
            throw CorruptionException("Session illisible", e)
        }
    }

    override suspend fun writeTo(
        t: SessionHolder,
        output: OutputStream,
    ) {
        val plain = json.encodeToString(SessionHolder.serializer(), t).encodeToByteArray()
        val encrypted =
            try {
                aead.get().encrypt(plain, ASSOCIATED_DATA)
            } catch (e: GeneralSecurityException) {
                throw SecureStorageUnavailableException("Chiffrement impossible", e)
            }
        output.write(encrypted)
    }

    companion object {
        /** Lie le chiffré à son usage : un autre fichier chiffré avec la même clé ne s'y substitue pas. */
        val ASSOCIATED_DATA: ByteArray = "fr.parcourses.secure-state.v1".encodeToByteArray()
    }
}
