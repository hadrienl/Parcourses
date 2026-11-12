package fr.parcourses.core.network.session

import com.google.crypto.tink.Aead

/** Fournit l'[Aead] du stockage chiffré. */
internal fun interface AeadSource {
    /**
     * @throws SecureStorageUnavailableException si la clé est inaccessible ou incertaine : le fichier est conservé.
     */
    fun get(): Aead
}

/** Matériel de clé de la session, que [SecureStateStore.resetSession] détruit à la demande de l'utilisateur. */
internal fun interface SessionKeys {
    /** @throws SecureStorageUnavailableException si le Keystore refuse l'effacement : rien n'est garanti. */
    fun destroy()

    companion object {
        /** Aucune clé à détruire (clé fournie par un test, stockage en mémoire). */
        val None = SessionKeys {}
    }
}

/** État de la clé maîtresse dans le Keystore. */
internal sealed interface MasterKeyState {
    data object Present : MasterKeyState

    /** Le Keystore a répondu, deux fois, et l'alias n'y est pas. */
    data object Absent : MasterKeyState

    /** Le Keystore ne répond pas (panne passagère, démarrage direct…) : on ne sait rien. */
    data class Unreachable(
        val cause: Throwable,
    ) : MasterKeyState
}

/** Protection du jeu de clés enregistré, vérifiée après chaque construction. */
internal sealed interface KeysetProtection {
    /** Le jeu de clés se déchiffre avec la clé maîtresse du Keystore. */
    data object Encrypted : KeysetProtection

    /** Le jeu de clés se lit sans la clé maîtresse : il est en clair sur le disque. */
    data object Cleartext : KeysetProtection

    /** Ni l'un ni l'autre n'a pu être établi (Keystore muet, lecture ratée) : on ne sait rien. */
    data class Unverifiable(
        val cause: Throwable,
    ) : KeysetProtection
}

/** Tout ce que [KeystoreAeadSource] touche sur l'appareil, séparé pour pouvoir le simuler. */
internal interface KeysetEnvironment {
    /** @throws SecureStorageUnavailableException si le stockage de l'app est illisible (appareil verrouillé). */
    fun checkAvailable()

    /**
     * Le jeu de clés Tink est présent dans les préférences.
     * @throws SecureStorageUnavailableException si les préférences existent mais ne se lisent pas : `false` serait
     *   pris pour un premier lancement.
     */
    fun keysetExists(): Boolean

    fun masterKeyState(): MasterKeyState

    /** Construit l'[Aead] ; crée le jeu de clés et la clé maîtresse au premier appel. */
    fun build(): Aead

    /** Relit le jeu de clés enregistré : Tink en écrit un en clair, sans erreur, si la clé maîtresse lui échappe. */
    fun keysetProtection(): KeysetProtection

    fun deleteKeyset()

    fun deleteMasterKey()
}

/**
 * Construit l'[Aead] sans jamais effacer par défaut : le matériel de clé n'est détruit que sur **preuve positive**
 * de perte, le Keystore ayant répondu :
 * - le jeu de clés existe mais l'alias de la clé maîtresse est absent ;
 * - ou le jeu de clés ne se déchiffre pas ([isCorruptionProof]) alors que l'alias est présent ;
 * - ou le jeu de clés se lit en clair : il ne protège plus rien.
 *
 * Toute autre erreur (clé invalidée, Keystore mort, `SecurityException`, E/S…) est incertaine : on lève
 * [SecureStorageUnavailableException] et rien n'est effacé, l'appelant réessaiera. Après une perte avérée, le
 * fichier de session devient illisible et est remplacé (nouvelle session anonyme) ; le dernier compte connu, lui,
 * est conservé (voir [AccountMarker]). Si l'incertitude ne se lève jamais, seule la personne peut trancher :
 * [destroy] (« Réinitialiser la session », écran À propos).
 *
 * L'[Aead] obtenu est gardé pour la vie du processus, jusqu'à [destroy].
 */
internal class KeystoreAeadSource(
    private val environment: KeysetEnvironment,
) : AeadSource,
    SessionKeys {
    private val lock = Any()
    private var cached: Aead? = null

    override fun get(): Aead =
        synchronized(lock) {
            cached ?: open().also { cached = it }
        }

    @Suppress("TooGenericExceptionCaught")
    override fun destroy() {
        synchronized(lock) {
            cached = null
            try {
                environment.deleteKeyset()
                environment.deleteMasterKey()
            } catch (e: Exception) {
                throw SecureStorageUnavailableException("Effacement de la clé de session impossible", e)
            }
        }
    }

    @Suppress("TooGenericExceptionCaught")
    private fun open(): Aead {
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
                val aead =
                    try {
                        environment.build()
                    } catch (e: Exception) {
                        // Seule une preuve de corruption, le Keystore répondant et l'alias existant, autorise
                        // l'effacement.
                        if (e.isCorruptionProof() && environment.masterKeyState() == MasterKeyState.Present) {
                            return recreate()
                        }
                        throw e
                    }
                when (val protection = environment.keysetProtection()) {
                    KeysetProtection.Encrypted -> aead

                    // Écrit en clair par un lancement précédent : la clé de session a pu être lue sur le disque.
                    KeysetProtection.Cleartext -> recreate()

                    is KeysetProtection.Unverifiable -> throw SecureStorageUnavailableException(
                        "Protection du jeu de clés invérifiable",
                        protection.cause,
                    )
                }
            }
        }

    private fun createFirst(): Aead = buildVerified()

    private fun recreate(): Aead {
        environment.deleteKeyset()
        environment.deleteMasterKey()
        return buildVerified()
    }

    /**
     * Le jeu de clés doit être protégé par une clé du Keystore : jamais laissé en clair. Il vient d'être créé et
     * n'a encore rien chiffré : l'effacer en cas de doute ne perd aucune donnée.
     */
    private fun buildVerified(): Aead {
        val aead = environment.build()
        val protection =
            if (environment.masterKeyState() == MasterKeyState.Present) {
                environment.keysetProtection()
            } else {
                KeysetProtection.Unverifiable(IllegalStateException("Clé maîtresse absente après création"))
            }
        if (protection != KeysetProtection.Encrypted) {
            environment.deleteKeyset()
            throw SecureStorageUnavailableException(
                "Jeu de clés non protégé par le Keystore",
                (protection as? KeysetProtection.Unverifiable)?.cause,
            )
        }
        return aead
    }
}

/**
 * Le jeu de clés est illisible pour de bon : étiquette AES-GCM refusée, protobuf invalide (sous-classes comprises,
 * comme `InvalidProtocolBufferException$InvalidWireTypeException`), ou valeur des préférences qui n'est pas de
 * l'hexadécimal (`CharConversionException`). On remonte la chaîne des causes et, pour chacune, ses superclasses.
 *
 * Comparaison par nom simple : `consumer-rules.pro` empêche R8 de renommer `InvalidProtocolBufferException` ; les
 * deux autres viennent de la plateforme et ne sont jamais renommées.
 */
internal fun Throwable.isCorruptionProof(): Boolean =
    generateSequence(this) { it.cause }.take(MAX_CAUSE_DEPTH).any { error ->
        generateSequence<Class<*>>(error.javaClass) { it.superclass }.any { it.simpleName in CORRUPTION_EXCEPTIONS }
    }

private const val MAX_CAUSE_DEPTH = 8
private val CORRUPTION_EXCEPTIONS =
    setOf("AEADBadTagException", "InvalidProtocolBufferException", "CharConversionException")
