package fr.parcourses.core.data.sync

import android.content.Context
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Curseurs de descente. Rien de personnel : de simples dates. */
interface SyncCursors {
    /** Compte auquel se rapportent `lists` et `items`. Le catalogue est commun. */
    var accountId: Uuid?
    var lists: Instant?
    var items: Instant?
    var catalog: Instant?
}

/** Curseurs en mémoire, pour les tests. */
class InMemorySyncCursors : SyncCursors {
    override var accountId: Uuid? = null
    override var lists: Instant? = null
    override var items: Instant? = null
    override var catalog: Instant? = null
}

/** Curseurs dans des préférences ordinaires (ni jeton ni donnée personnelle). Dates en ISO 8601. */
class SharedPreferencesSyncCursors(
    context: Context,
) : SyncCursors {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override var accountId: Uuid?
        get() = prefs.getString(ACCOUNT, null)?.let { runCatching { Uuid.parse(it) }.getOrNull() }
        set(value) = prefs.edit().putString(ACCOUNT, value?.toString()).apply()

    override var lists: Instant?
        get() = read(LISTS)
        set(value) = write(LISTS, value)

    override var items: Instant?
        get() = read(ITEMS)
        set(value) = write(ITEMS, value)

    override var catalog: Instant?
        get() = read(CATALOG)
        set(value) = write(CATALOG, value)

    private fun read(key: String): Instant? =
        prefs.getString(key, null)?.let {
            runCatching { Instant.parse(it) }.getOrNull()
        }

    private fun write(
        key: String,
        value: Instant?,
    ) = prefs.edit().putString(key, value?.toString()).apply()

    private companion object {
        const val FILE = "sync_cursors"
        const val ACCOUNT = "sync.cursor.account"
        const val LISTS = "sync.cursor.lists"
        const val ITEMS = "sync.cursor.items"
        const val CATALOG = "sync.cursor.catalog"
    }
}
