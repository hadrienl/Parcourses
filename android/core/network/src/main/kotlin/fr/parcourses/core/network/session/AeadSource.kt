package fr.parcourses.core.network.session

import com.google.crypto.tink.Aead

/** Fournit l'[Aead] du stockage chiffré. */
internal fun interface AeadSource {
    /**
     * @throws SecureStorageUnavailableException si la clé est inaccessible ou incertaine : le fichier est conservé.
     */
    fun get(): Aead
}

/** État de la clé maîtresse dans le Keystore. */
internal sealed interface MasterKeyState {
    data object Present : MasterKeyState

    /** Le Keystore a répondu et l'alias n'y est pas. */
    data object Absent : MasterKeyState

    /** Le Keystore ne répond pas (panne passagère, démarrage direct…) : on ne sait rien. */
    data class Unreachable(
        val cause: Throwable,
    ) : MasterKeyState
}

/** Tout ce que [KeystoreAeadSource] touche sur l'appareil, séparé pour pouvoir le simuler. */
internal interface KeysetEnvironment {
    /** @throws SecureStorageUnavailableException si le stockage de l'app est illisible (appareil verrouillé). */
    fun checkAvailable()

    /** Le jeu de clés Tink est présent dans les préférences. */
    fun keysetExists(): Boolean

    fun masterKeyState(): MasterKeyState

    /** Construit l'[Aead] ; crée le jeu de clés et la clé maîtresse au premier appel. */
    fun build(): Aead

    fun deleteKeyset()

    fun deleteMasterKey()
}

/**
 * Construit l'[Aead] sans jamais effacer par défaut : le matériel de clé n'est détruit que sur **preuve positive**
 * de perte, le Keystore ayant répondu :
 * - le jeu de clés existe mais l'alias de la clé maîtresse est absent ;
 * - ou le jeu de clés ne se déchiffre pas ([isCorruptionProof]) alors que l'alias est présent.
 *
 * Toute autre erreur (clé invalidée, Keystore mort, `SecurityException`, E/S…) est incertaine : on lève
 * [SecureStorageUnavailableException] et rien n'est effacé, l'appelant réessaiera. Après une perte avérée, le
 * fichier de session devient illisible et est remplacé (nouvelle session anonyme) ; le dernier compte connu, lui,
 * est conservé (voir [AccountMarker]).
 */
internal class KeystoreAeadSource(
    private val environment: KeysetEnvironment,
) : AeadSource {
    @Suppress("TooGenericExceptionCaught")
    override fun get(): Aead {
        environment.checkAvailable()
        return try {
            if (environment.keysetExists()) openExisting() else createFirst()
        } catch (e: SecureStorageUnavailableException) {
            throw e
        } catch (e: Exception) {
            throw SecureStorageUnavailableException("Clé de session inaccessible", e)
        }
    }

    @Suppress("TooGenericExceptionCaught")
    private fun openExisting(): Aead =
        when (val state = environment.masterKeyState()) {
            is MasterKeyState.Unreachable -> {
                throw SecureStorageUnavailableException("Keystore injoignable", state.cause)
            }

            MasterKeyState.Absent -> {
                recreate()
            }

            MasterKeyState.Present -> {
                try {
                    environment.build()
                } catch (e: Exception) {
                    // Seule une preuve de corruption, le Keystore répondant et l'alias existant, autorise l'effacement.
                    if (e.isCorruptionProof() && environment.masterKeyState() == MasterKeyState.Present) {
                        recreate()
                    } else {
                        throw e
                    }
                }
            }
        }

    private fun createFirst(): Aead = buildVerified()

    private fun recreate(): Aead {
        environment.deleteKeyset()
        environment.deleteMasterKey()
        return buildVerified()
    }

    /** Le jeu de clés doit être protégé par une clé du Keystore : jamais laissé en clair. */
    private fun buildVerified(): Aead {
        val aead = environment.build()
        if (environment.masterKeyState() != MasterKeyState.Present) {
            environment.deleteKeyset()
            throw SecureStorageUnavailableException("Clé maîtresse absente après création")
        }
        return aead
    }

    private fun Throwable.isCorruptionProof(): Boolean =
        generateSequence(this) { it.cause }.take(MAX_CAUSE_DEPTH).any {
            it.javaClass.simpleName in CORRUPTION_EXCEPTIONS
        }

    private companion object {
        const val MAX_CAUSE_DEPTH = 8
        val CORRUPTION_EXCEPTIONS = setOf("AEADBadTagException", "InvalidProtocolBufferException")
    }
}
