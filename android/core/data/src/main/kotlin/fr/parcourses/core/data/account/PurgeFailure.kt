package fr.parcourses.core.data.account

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update

/** Purge locale qui a échoué (#129). Mêmes noms et mêmes codes qu'iOS. */
enum class PurgeOperation(
    val code: String,
) {
    /** « Se déconnecter » : [AccountSignOut]. */
    SignOut("signout"),

    /** Rejeu d'un changement de compte e-mail interrompu : [AccountSwitchReplay]. */
    Switch("switch"),
}

/** Première étape en échec d'une purge (#129). Mêmes noms et mêmes codes qu'iOS. */
enum class PurgeStep(
    val code: String,
) {
    /** Base locale : `clearAllTables`, puis le journal WAL. */
    Store("store"),

    /** Référentiel des catégories amorcé de nouveau (`seedIfNeeded`). */
    Categories("categories"),

    /** Session : `signOut()`, session stockée, `acknowledgeAccount`, nouveau compte anonyme. */
    Session("session"),

    /** Curseurs, `account.kind`, drapeaux, préférences de la Live Update. */
    Preferences("preferences"),

    Unknown("unknown"),
}

/**
 * Purge en échec (#129) : opération et première étape en échec. Le code public ([publicCode]) va dans l'objet du
 * message de « Nous écrire » ([supportMailto]) et dans le journal ; jamais de donnée personnelle ni de texte d'erreur.
 */
data class PurgeFailure(
    val operation: PurgeOperation,
    val step: PurgeStep,
) {
    /** `purge-<opération>-<étape>`, par exemple `purge-signout-store`. */
    val publicCode: String get() = "purge-${operation.code}-${step.code}"

    /** Objet du message : « Parcourses : purge impossible (purge-signout-store) ». */
    val supportSubject: String get() = "Parcourses : purge impossible ($publicCode)"

    /** Adresse `mailto:` avec seulement l'objet, encodé pour l'URL ; sans corps. */
    val supportMailto: String get() = "mailto:$SUPPORT_ADDRESS?subject=${percentEncoded(supportSubject)}"

    companion object {
        const val SUPPORT_ADDRESS = "parcourses@hadrien.eu"

        private const val HEX = "0123456789ABCDEF"
        private const val BYTE_MASK = 0xFF
        private const val NIBBLE_MASK = 0x0F
        private const val NIBBLE_BITS = 4

        /**
         * Encodage RFC 3986 : seuls les caractères non réservés (`A-Za-z0-9-._~`) restent en clair, tout le reste passe
         * en `%XX` (UTF-8, majuscules). `Uri.encode` laisserait passer `(`, `)`, `!`, `*` et `'`.
         */
        internal fun percentEncoded(value: String): String =
            buildString {
                for (byte in value.encodeToByteArray()) {
                    val unsigned = byte.toInt() and BYTE_MASK
                    val char = unsigned.toChar()
                    if (char.isUnreserved()) {
                        append(char)
                    } else {
                        append('%')
                        append(HEX[unsigned shr NIBBLE_BITS])
                        append(HEX[unsigned and NIBBLE_MASK])
                    }
                }
            }

        private fun Char.isUnreserved(): Boolean =
            this in 'A'..'Z' || this in 'a'..'z' || this in '0'..'9' || this in "-._~"
    }
}

/**
 * Panne d'une étape de purge : porte l'étape, la cause reste à l'intérieur. Son message ne contient que le code de
 * l'étape : aucun texte d'erreur système n'en sort.
 */
class PurgeStepException(
    val step: PurgeStep,
    cause: Throwable,
) : Exception("purge step: ${step.code}", cause)

/**
 * Exécute une étape de purge : toute panne devient une [PurgeStepException] qui porte [step]. Une panne déjà
 * attribuée (étape imbriquée) garde la sienne : la première étape en échec compte. L'annulation passe telle quelle.
 */
@Suppress("TooGenericExceptionCaught") // Toute panne d'une étape est attribuée à cette étape.
inline fun <T> purgeStep(
    step: PurgeStep,
    block: () -> T,
): T =
    try {
        block()
    } catch (e: Exception) {
        throw attributed(step, e)
    }

/** Panne attribuée à [step], sauf l'annulation et une panne déjà attribuée. */
@PublishedApi
internal fun attributed(
    step: PurgeStep,
    error: Exception,
): Exception =
    when (error) {
        is CancellationException, is PurgeStepException -> error
        else -> PurgeStepException(step, error)
    }

/** Étape en échec portée par cette panne, sinon [PurgeStep.Unknown]. */
val Throwable.failedPurgeStep: PurgeStep get() = (this as? PurgeStepException)?.step ?: PurgeStep.Unknown

/** Nom de la cause, pour le journal : jamais son message. */
val Throwable.purgeCauseName: String get() = ((this as? PurgeStepException)?.cause ?: this).javaClass.simpleName

/** Ce que les purges signalent au compteur de [AccountSession] (#129). */
interface PurgeFailureRecorder {
    /** Purge en échec : le compteur monte. */
    fun purgeFailed(failure: PurgeFailure)

    /** Purge réussie : le compteur revient à 0. */
    fun purgeSucceeded()
}

/**
 * Compteur des purges en échec (#129), porté par [AccountSession] :
 * - **+1** à chaque purge en échec ([AccountSignOut], essai ou « Réessayer » ; [AccountSwitchReplay], au lancement ou
 *   au retour au premier plan) ;
 * - **0** à chaque purge réussie, et quand le drapeau `account.switch` qu'un rejeu en échec a laissé est effacé par un
 *   autre chemin ([switchFlagCleared]).
 *
 * En mémoire seulement. Seul le code public est journalisé : ni texte d'erreur, ni donnée personnelle.
 */
class PurgeFailureCounter : PurgeFailureRecorder {
    private val failureCount = MutableStateFlow(0)
    private val lastFailure = MutableStateFlow<PurgeFailure?>(null)

    /** `account.switch` laissé par un rejeu en échec, et pas encore effacé. */
    private val switchPending = MutableStateFlow(false)
    private val lock = Any()

    val count: StateFlow<Int> = failureCount.asStateFlow()
    val last: StateFlow<PurgeFailure?> = lastFailure.asStateFlow()

    /** Seuil franchi : la dernière purge en échec, sinon `null`. */
    val blocked: Flow<PurgeFailure?> =
        combine(failureCount, lastFailure) { count, last ->
            last.takeIf { count >= AccountSession.PURGE_FAILURE_THRESHOLD }
        }

    /** Seuil franchi, `account.switch` laissé par un rejeu en échec : la dernière purge en échec, sinon `null`. */
    val blockedSwitch: Flow<PurgeFailure?> =
        combine(failureCount, lastFailure, switchPending) { count, last, pending ->
            last.takeIf { pending && count >= AccountSession.PURGE_FAILURE_THRESHOLD }
        }

    override fun purgeFailed(failure: PurgeFailure) {
        synchronized(lock) {
            // Le code et le drapeau d'abord, le compteur ensuite : le seuil n'est jamais vu avec l'ancien code.
            lastFailure.value = failure
            // Un rejeu en échec laisse toujours `account.switch`.
            if (failure.operation == PurgeOperation.Switch) switchPending.value = true
            failureCount.update { it + 1 }
        }
        Log.w(TAG, "Purge impossible : ${failure.publicCode}")
    }

    override fun purgeSucceeded() = synchronized(lock) { reset() }

    /**
     * `account.switch` effacé (purge d'une déconnexion ou d'une suppression, connexion achevée, rejeu) : si un rejeu en
     * échec l'avait laissé, le compteur revient à 0. Sinon rien ne change : une déconnexion qui échoue après sa purge
     * (laquelle efface ce drapeau à chaque essai) continue de compter.
     */
    fun switchFlagCleared() =
        synchronized(lock) {
            if (switchPending.value) reset()
        }

    private fun reset() {
        // Le compteur d'abord : le seuil disparaît avant le code.
        failureCount.value = 0
        lastFailure.value = null
        switchPending.value = false
    }

    private companion object {
        const val TAG = "PurgeFailures"
    }
}
