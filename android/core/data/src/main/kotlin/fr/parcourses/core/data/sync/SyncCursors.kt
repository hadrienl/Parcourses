package fr.parcourses.core.data.sync

import android.content.Context
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Curseurs de descente. Rien de personnel : de simples dates, et des empreintes d'essais de résolution. */
interface SyncCursors {
    /** Compte auquel se rapportent `lists` et `items`. Le catalogue est commun. */
    var accountId: Uuid?
    var lists: Instant?
    var items: Instant?
    var catalog: Instant?

    /**
     * Plus récente date de publication reçue (#47, heure du serveur) : la descente suivante ne lit que les produits
     * publiés depuis. `null` : catalogue complet.
     */
    var catalogPublished: Instant?

    /**
     * Plus récente date de dépublication reçue (#138, heure du serveur) : la descente incrémentale ne lit que les
     * dépublications depuis. `null` : toutes. Le téléchargement complet ne la touche pas.
     */
    var catalogUnpublished: Instant?

    /** Dernier téléchargement complet du catalogue (#47) : il est refait chaque semaine. */
    var catalogFull: Instant?

    /** Essais de `resolve_products` par article (#47) : une empreinte et une date, rien de lisible. */
    var resolutionAttempts: Map<String, ResolutionAttempt>

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
    override var catalogPublished: Instant? = null
    override var catalogUnpublished: Instant? = null
    override var catalogFull: Instant? = null
    override var resolutionAttempts: Map<String, ResolutionAttempt> = emptyMap()
    override var tombstones: Instant? = null
    override var accountKind: AccountKind? = null

    override fun clear() {
        accountId = null
        lists = null
        items = null
        catalog = null
        catalogPublished = null
        catalogUnpublished = null
        catalogFull = null
        resolutionAttempts = emptyMap()
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

    override var catalogPublished: Instant?
        get() = read(CATALOG_PUBLISHED)
        set(value) = write(CATALOG_PUBLISHED, value)

    override var catalogUnpublished: Instant?
        get() = read(CATALOG_UNPUBLISHED)
        set(value) = write(CATALOG_UNPUBLISHED, value)

    override var catalogFull: Instant?
        get() = read(CATALOG_FULL)
        set(value) = write(CATALOG_FULL, value)

    /** Une ligne par article : `id fingerprint date` (ISO 8601). Ligne illisible : ignorée, l'article repart. */
    override var resolutionAttempts: Map<String, ResolutionAttempt>
        get() =
            prefs
                .getString(RESOLUTION_ATTEMPTS, null)
                .orEmpty()
                .lineSequence()
                .mapNotNull { line ->
                    val parts = line.split(' ')
                    if (parts.size != ATTEMPT_FIELDS) return@mapNotNull null
                    val at = runCatching { Instant.parse(parts[2]) }.getOrNull() ?: return@mapNotNull null
                    parts[0] to ResolutionAttempt(parts[1], at)
                }.toMap()
        set(value) =
            prefs
                .edit()
                .putString(
                    RESOLUTION_ATTEMPTS,
                    value.entries
                        .joinToString("\n") { (id, attempt) -> "$id ${attempt.fingerprint} ${attempt.at}" }
                        .ifEmpty { null },
                ).apply()

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
        const val CATALOG_PUBLISHED = "sync.cursor.catalogPublished"
        const val CATALOG_UNPUBLISHED = "sync.cursor.catalogUnpublished"
        const val CATALOG_FULL = "sync.cursor.catalogFull"
        const val RESOLUTION_ATTEMPTS = "sync.resolutionAttempts"
        const val ATTEMPT_FIELDS = 3
        const val ACCOUNT_KIND = "sync.cursor.accountKind"
    }
}
