package fr.parcourses.feature.lists

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Astuce unique de l'écran Liste (#110, `QuantityTip` d'iOS) : « Maintiens un article pour changer sa quantité ». Elle
 * devient montrable après le premier article ajouté par la saisie de cet appareil, et disparaît pour toujours quand on
 * la ferme ou dès qu'on a ouvert le panneau de l'article. Rien sur la liste ni sur l'article : deux drapeaux.
 */
interface QuantityTipMemory {
    /** Un article ajouté sur l'appareil, astuce jamais invalidée. */
    val isEligible: StateFlow<Boolean>

    /** Un article vient d'être ajouté par la saisie. */
    fun itemAdded()

    /** Astuce fermée, ou panneau de l'article ouvert : elle ne revient plus. */
    fun invalidate()
}

/** En mémoire : pour les tests, et pour une app sans stockage. */
class InMemoryQuantityTipMemory(
    itemAdded: Boolean = false,
    invalidated: Boolean = false,
) : QuantityTipMemory {
    private var added = itemAdded
    private var done = invalidated
    private val eligible = MutableStateFlow(added && !done)

    override val isEligible: StateFlow<Boolean> = eligible.asStateFlow()

    override fun itemAdded() {
        added = true
        eligible.value = !done
    }

    override fun invalidate() {
        done = true
        eligible.value = false
    }
}

/** Préférences de l'app : survit à la mort du processus. Écrit seulement quand un drapeau change. */
class SharedPreferencesQuantityTipMemory(
    context: Context,
) : QuantityTipMemory {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
    private val eligible = MutableStateFlow(read())

    override val isEligible: StateFlow<Boolean> = eligible.asStateFlow()

    private fun read(): Boolean = prefs.getBoolean(KEY_ITEM_ADDED, false) && !prefs.getBoolean(KEY_INVALIDATED, false)

    override fun itemAdded() {
        if (!prefs.getBoolean(KEY_ITEM_ADDED, false)) prefs.edit().putBoolean(KEY_ITEM_ADDED, true).apply()
        eligible.value = read()
    }

    override fun invalidate() {
        if (!prefs.getBoolean(KEY_INVALIDATED, false)) prefs.edit().putBoolean(KEY_INVALIDATED, true).apply()
        eligible.value = false
    }

    companion object {
        const val FILE = "quantity_tip"
        private const val KEY_ITEM_ADDED = "item_added"
        private const val KEY_INVALIDATED = "invalidated"
    }
}
