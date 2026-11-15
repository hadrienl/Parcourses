package fr.parcourses.core.data.account

import android.content.Context

/**
 * Drapeau durable `account.switch` (#87) : posé avant la vérification du code d'une connexion depuis un compte e-mail.
 * Si le processus meurt avant la fin, le lancement suivant compare la session au compte des données : un autre compte
 * rejoue la purge (aucune reprise), le même compte efface le drapeau. Tant qu'il existe, la synchronisation ne démarre
 * pas. Écrit et effacé de façon synchrone.
 */
interface AccountSwitchFlag {
    val isPending: Boolean

    fun write()

    fun clear()
}

/** Préférences `account_switch`, exclues de la sauvegarde et du transfert d'appareil (comme `account_deletion`). */
class SharedPreferencesAccountSwitchFlag(
    context: Context,
) : AccountSwitchFlag {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override val isPending: Boolean get() = prefs.getBoolean(KEY, false)

    override fun write() {
        check(prefs.edit().putBoolean(KEY, true).commit()) { "Drapeau de changement de compte non écrit" }
    }

    override fun clear() {
        check(prefs.edit().remove(KEY).commit()) { "Drapeau de changement de compte non effacé" }
    }

    companion object {
        /** `shared_prefs/account_switch.xml`, vérifié par `BackupRulesTest`. */
        const val FILE = "account_switch"
        const val KEY = "account.switch"
    }
}

/** Drapeau en mémoire, pour les tests. */
class InMemoryAccountSwitchFlag : AccountSwitchFlag {
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
