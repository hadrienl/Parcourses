package fr.parcourses.core.data.account

import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.core.data.sync.AccountKind

/**
 * Bouton compte de l'écran Listes (#108), toujours visible. Même nom et même règle qu'iOS : un compte anonyme se
 * connecte ([SignIn]) ; un compte e-mail ouvre l'écran Compte ([Account]), avec l'initiale de son prénom.
 */
sealed interface AccountEntry {
    /** « Se connecter » : lier une adresse, ou se reconnecter à un compte e-mail. */
    data object SignIn : AccountEntry

    /** Écran Compte. [initial] : pastille du prénom (`SharingDecisions.memberInitial`), `null` sans prénom. */
    data class Account(
        val initial: String?,
    ) : AccountEntry

    companion object {
        /** [displayName] vide ou blanc : pas d'initiale, l'icône personne la remplace. */
        fun of(
            kind: AccountKind,
            displayName: String?,
        ): AccountEntry =
            when (kind) {
                AccountKind.Anonymous -> {
                    SignIn
                }

                AccountKind.Email -> {
                    Account(initial = displayName?.takeIf { it.isNotBlank() }?.let(SharingDecisions::memberInitial))
                }
            }
    }
}
