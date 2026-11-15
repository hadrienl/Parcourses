package fr.parcourses.core.data.account

import android.content.Context
import fr.parcourses.core.data.sync.AccountKind
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Drapeau durable `account.kind` (#87 §2.4) : l'appareil a-t-il un compte e-mail ? Il survit à la perte de la session
 * (stockage chiffré vidé, transfert d'appareil) : un compte e-mail sans session attend la reconnexion au lieu d'en
 * recréer un anonyme (vecteur `009`). Effacé par [LocalDataPurge]. Écrit de façon synchrone.
 */
interface AccountKindFlag {
    /** Valeur courante, observée par les écrans. */
    val kind: StateFlow<AccountKind>

    /** Faux tant que rien n'a été écrit (installation d'avant #87, ou purge). */
    val isSet: Boolean

    fun write(kind: AccountKind)

    /** Retour à l'état d'un appareil neuf : compte anonyme. */
    fun clear()
}

/**
 * Préférences `account_kind`. Contrairement à `account_deletion`, elles **suivent** le transfert d'appareil : la base
 * le suit aussi, et un compte e-mail ainsi transféré, sans sa session (exclue), doit demander la reconnexion.
 */
class SharedPreferencesAccountKindFlag(
    context: Context,
) : AccountKindFlag {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
    private val current = MutableStateFlow(read())

    override val kind: StateFlow<AccountKind> = current.asStateFlow()

    override val isSet: Boolean get() = prefs.contains(KEY)

    // Valeur inconnue (version future) : un compte e-mail, par prudence, plutôt qu'un compte anonyme recréé.
    private fun read(): AccountKind =
        prefs.getString(KEY, null)?.let { AccountKind.fromWireName(it) ?: AccountKind.Email } ?: AccountKind.Anonymous

    override fun write(kind: AccountKind) {
        check(prefs.edit().putString(KEY, kind.wireName).commit()) { "Type de compte non écrit" }
        current.value = kind
    }

    override fun clear() {
        check(prefs.edit().remove(KEY).commit()) { "Type de compte non effacé" }
        current.value = AccountKind.Anonymous
    }

    companion object {
        const val FILE = "account_kind"
        const val KEY = "account.kind"
    }
}

/** Drapeau en mémoire, pour les tests. */
class InMemoryAccountKindFlag(
    initial: AccountKind? = null,
) : AccountKindFlag {
    private val current = MutableStateFlow(initial ?: AccountKind.Anonymous)

    override val kind: StateFlow<AccountKind> = current.asStateFlow()

    override var isSet: Boolean = initial != null
        private set

    override fun write(kind: AccountKind) {
        current.value = kind
        isSet = true
    }

    override fun clear() {
        current.value = AccountKind.Anonymous
        isSet = false
    }
}
