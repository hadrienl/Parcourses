package fr.parcourses.core.network.dto

/**
 * Usage d'un code reçu par e-mail (#87 §2.2). [Link] : lier une adresse au compte anonyme de la session (type GoTrue
 * `email_change`, même compte). [SignIn] : se connecter à un compte e-mail existant (type `email`, nouveau compte de
 * session). Mêmes noms qu'iOS (`EmailCodePurpose.link`, `.signIn`).
 */
enum class EmailCodePurpose(
    val wireName: String,
) {
    Link("link"),
    SignIn("signIn"),
}

/**
 * Réponse de GoTrue à une demande de code (`updateUser({ email })` ou `signInWithOtp`). Un refus HTTP n'est pas une
 * exception : son statut et son code (`email_exists`, `over_email_send_rate_limit`…) décident de la suite
 * (`SyncDecisions.linkEmailNextStep`). Le réseau, lui, lève `RemoteError.Network`.
 */
data class EmailCodeStatus(
    val status: Int,
    val errorCode: String?,
) {
    val isSent: Boolean get() = status in HTTP_SUCCESS

    companion object {
        private val HTTP_SUCCESS = 200..299
        const val HTTP_OK = 200

        val Sent = EmailCodeStatus(HTTP_OK, null)
    }
}
