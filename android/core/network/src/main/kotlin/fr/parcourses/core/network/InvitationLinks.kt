package fr.parcourses.core.network

/**
 * Liens d'invitation construits par l'app (#87, « Copier le lien »). [httpsHost] vient de la configuration de build
 * (`BuildConfig.INVITATION_HOST`, propriété Gradle `parcourses.invitationHost`, `parcourses.hadrien.eu` par défaut
 * depuis le lot 87.7, celui des App Links). Vide, le lien passe par le schéma de l'app.
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
