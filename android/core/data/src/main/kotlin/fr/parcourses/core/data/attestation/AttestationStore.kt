package fr.parcourses.core.data.attestation

import android.content.Context
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * État de l'attestation d'appareil (#137), **par id de compte**. Effacé par `LocalDataPurge`. Seul le dernier compte
 * écrit est gardé : un compte anonyme quitté ne revient jamais sur l'appareil (sa session part avec lui), et un compte
 * e-mail ne s'atteste pas.
 */
interface AttestationStore {
    /** État de [accountId], `null` s'il n'y en a pas (première tentative). */
    fun read(accountId: Uuid): AttestationState?

    /** Remplace l'état de [accountId] ; celui des autres comptes est retiré. */
    fun write(
        accountId: Uuid,
        state: AttestationState,
    )

    fun clear()
}

/**
 * Préférences `device_attestation`, **exclues** de la sauvegarde et du transfert d'appareil (`BackupRulesTest`) :
 * l'attestation prouve cet appareil-ci, et restaurée ailleurs elle dirait « déjà fait » ou « service absent » à tort.
 * Écrites de façon synchrone.
 */
class SharedPreferencesAttestationStore(
    context: Context,
) : AttestationStore {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun read(accountId: Uuid): AttestationState? {
        // Statut inconnu (version future) : traité comme absent, donc une nouvelle tentative.
        val status = AttestationStatus.fromWireName(prefs.getString(statusKey(accountId), null)) ?: return null
        val next = nextAttemptKey(accountId)
        val nextAttemptAt = if (prefs.contains(next)) Instant.fromEpochMilliseconds(prefs.getLong(next, 0)) else null
        return AttestationState(status, nextAttemptAt)
    }

    override fun write(
        accountId: Uuid,
        state: AttestationState,
    ) {
        // `clear` s'applique avant les écritures du même `edit` : les autres comptes partent, atomiquement.
        val editor = prefs.edit().clear().putString(statusKey(accountId), state.status.wireName)
        state.nextAttemptAt?.let { editor.putLong(nextAttemptKey(accountId), it.toEpochMilliseconds()) }
        check(editor.commit()) { "État de l'attestation non écrit" }
    }

    override fun clear() {
        check(prefs.edit().clear().commit()) { "État de l'attestation non effacé" }
    }

    companion object {
        /** `shared_prefs/device_attestation.xml`, vérifié par `BackupRulesTest`. */
        const val FILE = "device_attestation"

        /** Préfixe des clés : `attestation.<id>.status` et `attestation.<id>.nextAttemptAt` (millisecondes). */
        const val KEY_PREFIX = "attestation."

        fun statusKey(accountId: Uuid): String = "$KEY_PREFIX$accountId.status"

        fun nextAttemptKey(accountId: Uuid): String = "$KEY_PREFIX$accountId.nextAttemptAt"
    }
}

/** État en mémoire, pour les tests. */
class InMemoryAttestationStore : AttestationStore {
    private val states = mutableMapOf<Uuid, AttestationState>()

    @Synchronized
    override fun read(accountId: Uuid): AttestationState? = states[accountId]

    @Synchronized
    override fun write(
        accountId: Uuid,
        state: AttestationState,
    ) {
        states.clear()
        states[accountId] = state
    }

    @Synchronized
    override fun clear() = states.clear()
}
