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

    /**
     * Dernière pierre tombale lue (#87, heure du serveur). `null` : réconciliation complète des articles (premier
     * passage, reprise de compte), comme un curseur de plus de 29 jours (vecteur `007`).
     */
    var tombstones: Instant?

    /**
     * Type du compte de [accountId] (#87) : un ancien compte e-mail n'est jamais repris par un autre compte, ses
     * données quittent l'appareil. `null` (installation d'avant #87) : anonyme.
     */
    var accountKind: AccountKind?

    /** Oublie tous les curseurs, compte compris (suppression du compte, #68). Écrit avant de rendre la main. */
    fun clear()

    /**
     * Données de l'appareil rattachées à [accountId] (purge d'un changement de compte e-mail, #87) : écrit avant de
     * rendre la main, pour qu'une connexion à un autre compte avant la première passe ne passe pas pour le même.
     */
    fun adopt(
        accountId: Uuid,
        kind: AccountKind,
    ) {
        this.accountId = accountId
        accountKind = kind
    }
}

/** Curseurs en mémoire, pour les tests. */
class InMemorySyncCursors : SyncCursors {
    override var accountId: Uuid? = null
    override var lists: Instant? = null
    override var items: Instant? = null
    override var catalog: Instant? = null
    override var tombstones: Instant? = null
    override var accountKind: AccountKind? = null

    override fun clear() {
        accountId = null
        lists = null
        items = null
        catalog = null
        tombstones = null
        accountKind = null
    }
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

    override var tombstones: Instant?
        get() = read(TOMBSTONES)
        set(value) = write(TOMBSTONES, value)

    override var accountKind: AccountKind?
        get() = AccountKind.fromWireName(prefs.getString(ACCOUNT_KIND, null))
        set(value) = prefs.edit().putString(ACCOUNT_KIND, value?.wireName).apply()

    override fun adopt(
        accountId: Uuid,
        kind: AccountKind,
    ) {
        val written =
            prefs
                .edit()
                .putString(
                    ACCOUNT,
                    accountId.toString(),
                ).putString(ACCOUNT_KIND, kind.wireName)
                .commit()
        check(written) { "Compte des données non écrit" }
    }

    override fun clear() {
        // `commit` : le drapeau de suppression n'est effacé qu'après, il ne doit pas survivre à des curseurs perdus.
        check(prefs.edit().clear().commit()) { "Curseurs non effacés" }
    }

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
        const val TOMBSTONES = "sync.cursor.tombstones"
        const val ACCOUNT_KIND = "sync.cursor.accountKind"
    }
}
