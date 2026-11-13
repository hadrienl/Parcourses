package fr.parcourses.core.data.account

import android.content.Context
import kotlin.time.Instant

/** Étape atteinte par une suppression du compte, gardée dans le drapeau (#68 §5.3). Mêmes noms qu'iOS. */
enum class AccountDeletionPhase(
    val wireName: String,
) {
    /** Drapeau posé : la synchronisation est arrêtée, le serveur n'a peut-être encore rien supprimé. */
    Requested("requested"),

    /** Le serveur a confirmé la suppression : il ne reste qu'à purger l'appareil. */
    ServerDeleted("serverDeleted"),
    ;

    companion object {
        fun fromWireName(value: String): AccountDeletionPhase? = entries.firstOrNull { it.wireName == value }
    }
}

/**
 * Contenu du drapeau : l'étape, le compte visé quand on le connaissait (`null` : pas de session), et l'heure de la
 * dernière tentative de la RPC (`null` : jamais tentée). Une seule tentative passée suffit pour qu'un refus ne soit
 * plus cru sur parole : la précédente a peut-être supprimé le compte.
 */
data class AccountDeletionMarker(
    val phase: AccountDeletionPhase,
    val accountId: String?,
    val lastAttemptAt: Instant? = null,
)

/**
 * Drapeau durable `account.deletion` (#68 §5.3). Tant qu'il existe, la synchronisation ne démarre pas et aucun
 * compte n'est créé : le processus peut mourir à n'importe quelle étape, la suppression reprend au lancement.
 * Écrit et effacé de façon synchrone : l'appel ne rend la main qu'une fois le fichier sur le disque.
 */
interface AccountDeletionFlag {
    fun read(): AccountDeletionMarker?

    fun write(marker: AccountDeletionMarker)

    fun clear()

    val isPending: Boolean get() = read() != null
}

/**
 * Drapeau dans les préférences `account_deletion`, **exclues** de la sauvegarde et du transfert d'appareil
 * (`data_extraction_rules.xml`, `backup_rules.xml`) : un drapeau restauré bloquerait la synchronisation d'un
 * autre appareil.
 */
class SharedPreferencesAccountDeletionFlag(
    context: Context,
) : AccountDeletionFlag {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** `<phase>:<dernière tentative, ms>:<compte>`, champs vides pour `null`. */
    override fun read(): AccountDeletionMarker? {
        val value = prefs.getString(KEY, null) ?: return null
        val fields = value.split(SEPARATOR, limit = FIELDS)
        // Étape illisible (version future) : la suppression reprend au début. Tentative illisible : tenue pour faite.
        val attempt = fields.getOrNull(1).orEmpty()
        return AccountDeletionMarker(
            phase = AccountDeletionPhase.fromWireName(fields[0]) ?: AccountDeletionPhase.Requested,
            accountId = fields.getOrNull(2)?.ifEmpty { null },
            lastAttemptAt =
                if (attempt.isEmpty()) null else Instant.fromEpochMilliseconds(attempt.toLongOrNull() ?: 0L),
        )
    }

    override fun write(marker: AccountDeletionMarker) {
        val attempt = marker.lastAttemptAt?.toEpochMilliseconds()?.toString().orEmpty()
        val value = listOf(marker.phase.wireName, attempt, marker.accountId.orEmpty()).joinToString(SEPARATOR)
        check(prefs.edit().putString(KEY, value).commit()) { "Drapeau de suppression non écrit" }
    }

    override fun clear() {
        check(prefs.edit().remove(KEY).commit()) { "Drapeau de suppression non effacé" }
    }

    companion object {
        /** `shared_prefs/account_deletion.xml`, vérifié par `BackupRulesTest`. */
        const val FILE = "account_deletion"
        const val KEY = "account.deletion"
        private const val SEPARATOR = ":"
        private const val FIELDS = 3
    }
}

/** Drapeau en mémoire, pour les tests. */
class InMemoryAccountDeletionFlag : AccountDeletionFlag {
    @Volatile
    var marker: AccountDeletionMarker? = null

    override fun read(): AccountDeletionMarker? = marker

    override fun write(marker: AccountDeletionMarker) {
        this.marker = marker
    }

    override fun clear() {
        marker = null
    }
}
