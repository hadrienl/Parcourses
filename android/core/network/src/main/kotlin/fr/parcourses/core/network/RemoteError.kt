package fr.parcourses.core.network

/**
 * Erreur distante classée pour la file d'envoi (contrat hors ligne de `docs/data-model.md`).
 * Même classification que `RemoteError` côté iOS (`ios/Parcourses/Data/Remote/RemoteGateway.swift`).
 */
sealed class RemoteError(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause) {
    /**
     * Pas de réseau ou requête interrompue. [notSent] : la requête n'a jamais quitté l'appareil (hôte introuvable,
     * connexion refusée, pas de route) ; sinon elle a pu arriver au serveur (délai, connexion coupée en cours).
     */
    class Network(
        cause: Throwable? = null,
        val notSent: Boolean = false,
    ) : RemoteError(if (notSent) "network not sent" else "network", cause)

    /**
     * Session absente ou expirée. [authCode] : le code GoTrue (`error_code`) quand le serveur l'a donné, par exemple
     * `user_not_found` ou `refresh_token_not_found` après une suppression du compte (#68). [noLocalSession] :
     * l'appareil n'a aucune session, rien n'a été demandé au serveur.
     */
    class Unauthorized(
        cause: Throwable? = null,
        val authCode: String? = null,
        val noLocalSession: Boolean = false,
    ) : RemoteError(authCode?.let { "unauthorized $it" } ?: "unauthorized", cause)

    /** Code `42501` uniquement : refus RLS ou privilège. Un 403 sans code n'en est pas un ([Server]). */
    class Forbidden(
        cause: Throwable? = null,
    ) : RemoteError("forbidden", cause)

    /** `23514` et `23505` : renvoyer la même ligne ne changerait rien. */
    class Constraint(
        val code: String,
        cause: Throwable? = null,
    ) : RemoteError("constraint $code", cause)

    /** `23503` : la ligne parente n'est pas encore arrivée. Réessai à plafonner. */
    class DependencyMissing(
        val code: String,
        cause: Throwable? = null,
    ) : RemoteError("dependency missing $code", cause)

    /** Requête invalide, définitive. */
    class Rejected(
        val code: String,
        cause: Throwable? = null,
    ) : RemoteError("rejected $code", cause)

    /** Erreur côté serveur ou passerelle (code PostgREST ou statut HTTP). */
    class Server(
        val code: String,
        cause: Throwable? = null,
    ) : RemoteError("server $code", cause)

    /** Réponse illisible, sans code ni statut exploitable. Réessayable : on ne sait pas si la ligne est passée. */
    class Unexpected(
        cause: Throwable? = null,
    ) : RemoteError("unexpected", cause)

    /**
     * La session appartient à un autre compte que le dernier connu : les lignes existantes ne sont plus
     * visibles. La synchronisation réidentifie alors les données locales.
     */
    class AccountChanged : RemoteError("account changed")

    /** Catégorie absente de la table serveur, même après relecture. Jamais abandonnée. */
    class UnknownCategory(
        val slug: String,
    ) : RemoteError("unknown category $slug")

    /**
     * Stockage chiffré indisponible (Keystore ou fichier illisible, démarrage direct avant déverrouillage) :
     * la session existe peut-être encore. Équivalent Android de `keychainLocked`.
     */
    class SecureStorageLocked(
        cause: Throwable? = null,
    ) : RemoteError("secure storage locked", cause)

    /** `true` si l'élément doit rester dans la file. */
    val isRetryable: Boolean
        get() =
            when (this) {
                is Network, is Unauthorized, is DependencyMissing, is Server, is Unexpected,
                is AccountChanged, is UnknownCategory, is SecureStorageLocked,
                -> true

                is Forbidden, is Constraint, is Rejected -> false
            }

    /** 4xx sans code : ni réessai sans fin, ni abandon immédiat. 403, 408 et 429 restent passagers. */
    val isCappedClientFailure: Boolean
        get() {
            val status = (this as? Server)?.code?.toIntOrNull() ?: return false
            return status in HTTP_CLIENT_ERRORS && status !in TRANSIENT_CLIENT_STATUSES
        }

    companion object {
        /** PostgREST ne trouve pas la fonction appelée : serveur en retard d'une migration. */
        const val FUNCTION_NOT_FOUND_CODE = "PGRST202"

        private const val HTTP_UNAUTHORIZED = 401
        private val HTTP_CLIENT_ERRORS = 400..499
        private val TRANSIENT_CLIENT_STATUSES = setOf(403, 408, 429)
        private val UNAUTHORIZED_CODES = setOf("PGRST301", "PGRST302", "PGRST303")
        private val REJECTED_PREFIXES = listOf("PGRST", "22", "23", "42", "P0")

        /** Classe un code renvoyé par PostgREST (SQLSTATE ou `PGRSTxxx`). */
        fun fromPostgrest(
            code: String?,
            cause: Throwable? = null,
        ): RemoteError =
            when {
                code == null -> Unexpected(cause)

                code == "42501" -> Forbidden(cause)

                code == "23514" || code == "23505" -> Constraint(code, cause)

                code == "23503" -> DependencyMissing(code, cause)

                code in UNAUTHORIZED_CODES -> Unauthorized(cause)

                // PGRST0xx : base injoignable ou saturée ; PGRST5xx : erreur interne.
                code.startsWith("PGRST0") || code.startsWith("PGRST5") -> Server(code, cause)

                // Autres PGRST : requête mal formée ; 22, 23, 42, P0 : données ou SQL refusés.
                REJECTED_PREFIXES.any(code::startsWith) -> Rejected(code, cause)

                else -> Server(code, cause)
            }

        /**
         * Classe un statut HTTP pour les réponses sans code PostgREST. Un 403 de passerelle reste réessayable :
         * le traiter comme un refus RLS ferait disparaître une coche jamais reçue.
         */
        fun fromHttp(
            status: Int,
            cause: Throwable? = null,
        ): RemoteError = if (status == HTTP_UNAUTHORIZED) Unauthorized(cause) else Server(status.toString(), cause)
    }
}
