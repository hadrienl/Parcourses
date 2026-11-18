package fr.parcourses.core.network

import kotlin.uuid.Uuid

/**
 * Accès à l'Edge Function `attest-device` (#137, protocole dans `shared/test-vectors/attestation/README.md`).
 * [SupabaseGateway] en est l'implémentation. Aucune méthode ne crée de compte.
 */
interface AttestationGateway {
    /**
     * Compte de la session, s'il est le dernier compte connu, et son type ; sans réseau sauf rafraîchissement d'un
     * jeton qui expire. [RemoteError.Unauthorized] sans session, [RemoteError.AccountChanged] si le compte a changé
     * sans réidentification des données, [RemoteError.SecureStorageLocked] si le stockage chiffré est illisible.
     */
    suspend fun attestationAccount(): AttestationAccount

    /** `POST {"step": "challenge", "platform": "android"}`. */
    suspend fun attestationChallenge(): AttestationReply

    /** `POST {"step": "verify", "platform": "android", "challenge", "token"}`, [token] : le jeton Play Integrity. */
    suspend fun verifyAttestation(
        challenge: String,
        token: String,
    ): AttestationReply
}

/** Compte de la session, vu par l'attestation. */
data class AttestationAccount(
    val id: Uuid,
    /** Faux pour un compte e-mail, et quand GoTrue ne dit rien : rien n'est alors envoyé à Google. */
    val isAnonymous: Boolean,
)

/**
 * Réponse HTTP de `attest-device`, quel que soit son statut. Les champs du corps sont nuls s'ils manquent ou si le
 * corps est illisible. Pas de réponse du tout (réseau) : [RemoteError] levée, que l'appelant lit comme le statut 0.
 */
data class AttestationReply(
    val httpStatus: Int,
    val status: String?,
    val error: String?,
    /** Défi en base64url sans remplissage (43 caractères), avec `status = challenge`. */
    val challenge: String?,
)
