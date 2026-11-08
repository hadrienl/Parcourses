package fr.parcourses.core.network.session

import androidx.datastore.core.CorruptionException
import androidx.datastore.core.Serializer
import com.google.crypto.tink.Aead
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import java.io.InputStream
import java.io.OutputStream
import java.security.GeneralSecurityException

/**
 * Sérialiseur DataStore : JSON chiffré en AES-256-GCM (Tink). Le fichier ne contient jamais de texte clair.
 *
 * [aead] est résolu à chaque accès : si le Keystore est indisponible, l'erreur remonte en
 * [SecureStorageUnavailableException] et le fichier n'est **pas** remplacé. Seul un fichier qui ne se
 * déchiffre pas avec une clé disponible est déclaré corrompu ([CorruptionException]).
 */
internal class AeadStateSerializer(
    private val aead: () -> Aead,
    private val json: Json = Json { ignoreUnknownKeys = true },
) : Serializer<SecureState> {
    override val defaultValue: SecureState = SecureState()

    override suspend fun readFrom(input: InputStream): SecureState {
        val bytes = input.readBytes()
        if (bytes.isEmpty()) return defaultValue
        val cipher = resolveAead()
        return try {
            json.decodeFromString(SecureState.serializer(), cipher.decrypt(bytes, ASSOCIATED_DATA).decodeToString())
        } catch (e: GeneralSecurityException) {
            throw CorruptionException("Session illisible avec la clé courante", e)
        } catch (e: SerializationException) {
            throw CorruptionException("Session illisible", e)
        }
    }

    override suspend fun writeTo(
        t: SecureState,
        output: OutputStream,
    ) {
        val plain = json.encodeToString(SecureState.serializer(), t).encodeToByteArray()
        val encrypted =
            try {
                resolveAead().encrypt(plain, ASSOCIATED_DATA)
            } catch (e: GeneralSecurityException) {
                throw SecureStorageUnavailableException("Chiffrement impossible", e)
            }
        output.write(encrypted)
    }

    private fun resolveAead(): Aead =
        try {
            aead()
        } catch (e: GeneralSecurityException) {
            throw SecureStorageUnavailableException("Clé du Keystore indisponible", e)
        } catch (e: java.io.IOException) {
            throw SecureStorageUnavailableException("Jeu de clés illisible", e)
        }

    companion object {
        /** Lie le chiffré à son usage : un autre fichier chiffré avec la même clé ne s'y substitue pas. */
        val ASSOCIATED_DATA: ByteArray = "fr.parcourses.secure-state.v1".encodeToByteArray()
    }
}
