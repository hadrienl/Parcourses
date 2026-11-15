package fr.parcourses.core.data.account

import android.content.Context

/**
 * Drapeau durable de « Se déconnecter » (#87), posé **avant** `signOut()` : tant qu'il existe, la synchronisation ne
 * démarre pas et la purge de l'appareil est rejouée au lancement. Écrit et effacé de façon synchrone.
 */
interface AccountSignOutFlag {
    val isPending: Boolean

    fun write()

    fun clear()
}

/**
 * Préférences `account_sign_out`, **exclues** de la sauvegarde et du transfert d'appareil (comme `account_deletion`) :
 * restauré ailleurs, le drapeau y purgerait des données que personne n'a demandé d'effacer.
 */
class SharedPreferencesAccountSignOutFlag(
    context: Context,
) : AccountSignOutFlag {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override val isPending: Boolean get() = prefs.getBoolean(KEY, false)

    override fun write() {
        check(prefs.edit().putBoolean(KEY, true).commit()) { "Drapeau de déconnexion non écrit" }
    }

    override fun clear() {
        check(prefs.edit().remove(KEY).commit()) { "Drapeau de déconnexion non effacé" }
    }

    companion object {
        /** `shared_prefs/account_sign_out.xml`, vérifié par `BackupRulesTest`. */
        const val FILE = "account_sign_out"
        const val KEY = "account.signOut"
    }
}

/** Drapeau en mémoire, pour les tests. */
class InMemoryAccountSignOutFlag : AccountSignOutFlag {
    @Volatile
    override var isPending: Boolean = false
        private set

    override fun write() {
        isPending = true
    }

    override fun clear() {
        isPending = false
    }
}
