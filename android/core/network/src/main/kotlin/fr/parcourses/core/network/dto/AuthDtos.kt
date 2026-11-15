package fr.parcourses.core.network.dto

import kotlin.uuid.Uuid

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
