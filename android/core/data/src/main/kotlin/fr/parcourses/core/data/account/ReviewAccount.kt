package fr.parcourses.core.data.account

/**
 * Compte de revue des stores (#149), pour les relecteurs d'Apple et de Google, qui ne lisent pas de boîte mail. À
 * cette adresse, l'app n'envoie aucun code : elle passe directement à la saisie du code, et le code fixe est vérifié
 * par l'Edge Function `review-sign-in` ([fr.parcourses.core.network.dto.EmailCodePurpose.Review]). Même constante
 * qu'iOS (`ReviewAccount.email`).
 */
object ReviewAccount {
    /** Adresse du compte de revue, sur un domaine du projet : personne d'autre ne peut y recevoir de code. */
    const val EMAIL = "revue@parcourses.hadrien.eu"

    /** L'adresse, déjà normalisée ([AccountLink.normalizedEmail]), est celle du compte de revue. */
    fun matches(normalizedEmail: String): Boolean = normalizedEmail == EMAIL
}
