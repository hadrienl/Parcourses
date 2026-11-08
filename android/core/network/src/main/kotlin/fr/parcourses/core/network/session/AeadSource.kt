package fr.parcourses.core.network.session

import com.google.crypto.tink.Aead
import java.security.ProviderException

/** Fournit l'[Aead] du stockage chiffré. */
internal fun interface AeadSource {
    /**
     * @throws SecureStorageUnavailableException si la clé est momentanément inaccessible : le fichier est conservé.
     */
    fun get(): Aead
}

/**
 * Construit l'[Aead] et distingue deux pannes de clé :
 * - **passagère** (Keystore occupé ou mort, stockage non déverrouillé) : [SecureStorageUnavailableException], rien
 *   n'est effacé, l'appelant réessaiera ;
 * - **définitive** (clé maîtresse disparue après une réinitialisation du Keystore ou une mise à jour système,
 *   jeu de clés illisible) : le matériel de clé est effacé par [reset], puis une nouvelle clé est créée. L'ancien
 *   fichier de session devient illisible et est remplacé : nouvelle session anonyme (le dernier compte connu,
 *   lui, est conservé, voir [AccountMarker]).
 */
internal class RecoveringAeadSource(
    private val build: () -> Aead,
    private val reset: () -> Unit,
) : AeadSource {
    @Suppress("TooGenericExceptionCaught")
    override fun get(): Aead =
        try {
            build()
        } catch (e: SecureStorageUnavailableException) {
            throw e
        } catch (e: Exception) {
            if (e.isTransient()) throw SecureStorageUnavailableException("Keystore indisponible", e)
            recreate(e)
        }

    @Suppress("TooGenericExceptionCaught")
    private fun recreate(cause: Exception): Aead =
        try {
            reset()
            build()
        } catch (e: Exception) {
            e.addSuppressed(cause)
            throw SecureStorageUnavailableException("Clé de session irrécupérable", e)
        }

    private fun Throwable.isTransient(): Boolean =
        generateSequence(this) { it.cause }.take(MAX_CAUSE_DEPTH).any {
            it is ProviderException || it.javaClass.name == "android.os.DeadObjectException"
        }

    private companion object {
        const val MAX_CAUSE_DEPTH = 8
    }
}
