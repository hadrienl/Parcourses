package fr.parcourses.core.network.dto

import io.github.jan.supabase.auth.user.UserInfo
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * Usage d'un code reçu par e-mail (#87 §2.2). [Link] : lier une adresse au compte anonyme de la session (type GoTrue
 * `email_change`, même compte). [SignIn] : se connecter à un compte e-mail existant (type `email`, nouveau compte de
 * session). [Review] : compte de revue des stores (#149), aucun e-mail envoyé, code fixe vérifié par l'Edge Function
 * `review-sign-in` ; la suite est celle de [SignIn]. Mêmes noms qu'iOS (`EmailCodePurpose.link`, `.signIn`,
 * `.review`).
 */
enum class EmailCodePurpose(
    val wireName: String,
) {
    Link("link"),
    SignIn("signIn"),
    Review("review"),
}

/**
 * Code accepté (même nom qu'iOS). [previousAnonymousToken] : connexion depuis un compte anonyme vers un autre compte,
 * le jeton d'accès de l'anonyme (valable une heure), gardé en mémoire pour le supprimer après la reprise
 * (`deleteAccount(accessToken)`, #87 §2.3) ; `null` sinon.
 */
class VerifiedCode(
    val accountId: Uuid,
    val previousAnonymousToken: String?,
) {
    override fun equals(other: Any?): Boolean =
        other is VerifiedCode && accountId == other.accountId && previousAnonymousToken == other.previousAnonymousToken

    override fun hashCode(): Int = accountId.hashCode()

    // Le jeton n'apparaît jamais dans un journal.
    override fun toString(): String = "VerifiedCode($accountId)"
}

/**
 * Réponse `200` de l'Edge Function `review-sign-in` (#149) : la session GoTrue du compte de revue, et son compte
 * ([userId]). [expiresAt] : échéance en secondes depuis l'époque Unix ; absente, elle est déduite de [expiresIn].
 */
@Serializable
internal class ReviewSession(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String,
    @SerialName("expires_in") val expiresIn: Long,
    @SerialName("expires_at") val expiresAt: Long? = null,
    @SerialName("token_type") val tokenType: String = "bearer",
    @SerialName("user_id") val userId: String,
) {
    /** Session à importer dans supabase-kt, avec son compte lu par `/user` ([user]). */
    fun toUserSession(user: UserInfo): UserSession {
        val session =
            UserSession(
                accessToken = accessToken,
                refreshToken = refreshToken,
                expiresIn = expiresIn,
                tokenType = tokenType,
                user = user,
            )
        return expiresAt?.let { session.copy(expiresAt = Instant.fromEpochSeconds(it)) } ?: session
    }

    // Les jetons n'apparaissent jamais dans un journal.
    override fun toString(): String = "ReviewSession($userId)"
}
