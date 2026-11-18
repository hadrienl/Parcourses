package fr.parcourses.core.data.account

/**
 * Compte de revue des stores (#149), pour les relecteurs d'Apple et de Google, qui ne lisent pas de boîte mail. À
 * cette adresse, l'app n'envoie aucun code : elle passe directement à la saisie du code, et le code fixe est vérifié
 * par l'Edge Function `review-sign-in` ([fr.parcourses.core.network.dto.EmailCodePurpose.Review]). Même règle
 * qu'iOS (`ReviewAccount.matches`).
 *
 * L'adresse exacte n'est pas dans l'app : `revue-` suivi d'un suffixe aléatoire, choisi au réglage du serveur et connu
 * seulement des consoles des stores. Quelqu'un qui lit l'APK ne peut donc pas épuiser les plafonds d'essais, qui ne
 * comptent que l'adresse réglée. Le domaine est à nous : personne d'autre n'y reçoit de code.
 */
object ReviewAccount {
    private val ADDRESS = Regex("revue-[a-z0-9]{6,32}@parcourses\\.hadrien\\.eu")

    /** L'adresse, déjà normalisée ([AccountLink.normalizedEmail]), a la forme d'une adresse de revue. */
    fun matches(normalizedEmail: String): Boolean = ADDRESS.matches(normalizedEmail)
}
