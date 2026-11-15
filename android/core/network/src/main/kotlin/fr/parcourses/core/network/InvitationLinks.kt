package fr.parcourses.core.network

/**
 * Liens d'invitation construits par l'app (#87, « Copier le lien »). [httpsHost] vient de la configuration de build
 * (`BuildConfig.INVITATION_HOST`, propriété Gradle `parcourses.invitationHost`) et reste **vide** par défaut jusqu'aux
 * App Links du lot 87.7 : le lien passe alors par le schéma de l'app. Aucun domaine écrit en dur.
 */
class InvitationLinks(
    httpsHost: String?,
) {
    /** Hôte des liens https, `null` sans domaine configuré. */
    val httpsHost: String? = httpsHost?.trim()?.takeIf { it.isNotEmpty() }

    /** `https://<hôte>/i/#<jeton>` si l'hôte est défini, sinon `parcourses://invitation#<jeton>`. */
    fun link(token: String): String = httpsHost?.let { "https://$it/i/#$token" } ?: "$SCHEME_PREFIX$token"

    companion object {
        /** Lien du schéma de l'app, reconnu quel que soit l'hôte. */
        const val SCHEME_PREFIX = "parcourses://invitation#"
    }
}
