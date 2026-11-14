package fr.parcourses.core.data.account

import android.util.Log
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.LinkEmailNextStep
import fr.parcourses.core.data.sync.SyncDecisions
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.dto.EmailCodePurpose
import fr.parcourses.core.network.dto.EmailCodeStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Étape de la liaison d'une adresse ou de la connexion (#87 §2.2). Mêmes noms qu'iOS. */
enum class AccountLinkPhase(
    val wireName: String,
) {
    /** Adresse (et prénom pour un compte anonyme), puis « Recevoir un code ». */
    EnterEmail("enterEmail"),

    /** Code à 6 chiffres reçu par e-mail. */
    EnterCode("enterCode"),

    /** Reprise des données du téléphone par le compte existant (`AccountRekey`). */
    Merging("merging"),

    Done("done"),
}

/** Pourquoi une étape n'a pas abouti. Mêmes noms qu'iOS. */
enum class AccountLinkError(
    val wireName: String,
) {
    InvalidEmail("invalidEmail"),
    InvalidCode("invalidCode"),
    ExpiredCode("expiredCode"),
    RateLimited("rateLimited"),
    Offline("offline"),
    Unknown("unknown"),
}

/** Où en est la liaison, pour l'écran. */
data class AccountLinkState(
    val phase: AccountLinkPhase = AccountLinkPhase.EnterEmail,
    /** Le prénom est demandé : compte anonyme, une adresse nouvelle créera le compte e-mail (Q3). */
    val asksDisplayName: Boolean = true,
    val email: String = "",
    val purpose: EmailCodePurpose? = null,
    /** Heure d'envoi du dernier code : « Renvoyer le code » s'active [AccountLink.RESEND_DELAY] après. */
    val codeSentAt: Instant? = null,
    val error: AccountLinkError? = null,
    val busy: Boolean = false,
    /** Fin d'une connexion à un compte existant : « Bon retour ». */
    val welcomeBack: Boolean = false,
    /** Listes de ce téléphone ajoutées au compte (Q8). */
    val listsAdded: Int = 0,
    val displayName: String? = null,
)

/** Ce que la liaison demande à l'app autour du serveur. */
interface AccountLinkHost {
    /**
     * Reprend tout de suite les données locales pour le compte [expected] de la nouvelle session
     * (`SyncEngine.adoptSessionAccount`) : nombre de listes ajoutées, `null` si la reprise attend la synchronisation.
     */
    suspend fun adoptAccount(expected: Uuid): Int?

    /** Nouvelle session : la synchronisation reprend avec une descente. */
    fun sessionDidChange()
}

/**
 * Déroulé de la liaison d'une adresse e-mail (#87 §2.2, vecteur `010`), une instance par écran :
 * - compte anonyme : `linkEmail`, puis le code de liaison (`EmailCodePurpose.Link`, même compte) ; adresse déjà prise
 *   (`email_exists`) : `signInWithEmail`, puis le code de connexion (`SignIn`), puis la reprise des données du
 *   téléphone (`AccountRekey`) et la suppression de l'ancien compte anonyme avec son jeton gardé avant le code ;
 * - compte e-mail sans session (vecteur `009`) : `signInWithEmail`, puis le code de connexion.
 *
 * Le drapeau `account.kind` passe à `email` dès que le code est accepté. Le jeton de l'ancien compte reste en mémoire.
 */
@Suppress("TooManyFunctions")
class AccountLink(
    private val gateway: RemoteGateway,
    private val kind: AccountKindFlag,
    private val host: AccountLinkHost,
    private val isOnline: () -> Boolean,
    private val now: () -> Instant = { Clock.System.now() },
    private val mergeTimeout: Duration = MERGE_TIMEOUT,
) {
    private val lock = Mutex()
    private val current =
        MutableStateFlow(AccountLinkState(asksDisplayName = kind.kind.value == AccountKind.Anonymous))
    val state: StateFlow<AccountLinkState> = current.asStateFlow()

    private var pendingName: String? = null
    private var previousToken: String? = null
    private var previousAccount: Uuid? = null

    /** « Recevoir un code ». [displayName] : prénom saisi, écrit une fois le compte e-mail ouvert. */
    suspend fun requestCode(
        email: String,
        displayName: String? = null,
    ) = lock.withLock {
        val address = normalizedEmail(email) ?: return@withLock fail(AccountLinkError.InvalidEmail)
        pendingName = displayName?.let(::cleanedDisplayName)
        current.update { it.copy(email = address) }
        send(address)
    }

    /** « Renvoyer le code », même adresse, même usage. */
    suspend fun resendCode() =
        lock.withLock {
            val address = current.value.email
            if (address.isEmpty()) return@withLock
            send(address)
        }

    /** « Changer d'adresse » : retour à la saisie, adresse gardée. */
    fun changeEmail() {
        current.update { it.copy(phase = AccountLinkPhase.EnterEmail, error = null, purpose = null, codeSentAt = null) }
    }

    /** Efface le message d'erreur (saisie modifiée). */
    fun clearError() = current.update { it.copy(error = null) }

    /** Code saisi : validé dès le 6ᵉ chiffre par l'écran. */
    @Suppress("ReturnCount") // Une garde par cas : code, réseau, étape.
    suspend fun verify(code: String) =
        lock.withLock {
            val state = current.value
            val purpose = state.purpose ?: return@withLock
            if (state.phase != AccountLinkPhase.EnterCode) return@withLock
            val digits = code.filter(Char::isDigit)
            if (digits.length != CODE_LENGTH) return@withLock fail(AccountLinkError.InvalidCode)
            if (!isOnline()) return@withLock fail(AccountLinkError.Offline)
            current.update { it.copy(busy = true, error = null) }
            rememberPreviousAccount(purpose)
            val account =
                try {
                    gateway.verifyCode(state.email, digits, purpose)
                } catch (e: RemoteError) {
                    Log.i(TAG, "Code refusé : ${e.message}")
                    return@withLock fail(codeError(e, state.codeSentAt))
                }
            kind.write(AccountKind.Email)
            current.update { it.copy(phase = AccountLinkPhase.Merging, error = null) }
            finish(account, purpose)
        }

    private suspend fun send(address: String) {
        if (!isOnline()) return fail(AccountLinkError.Offline)
        current.update { it.copy(busy = true, error = null) }
        val purpose =
            try {
                request(address)
            } catch (e: RemoteError) {
                Log.i(TAG, "Code non envoyé : ${e.message}")
                return fail(if (e is RemoteError.Network) AccountLinkError.Offline else AccountLinkError.Unknown)
            }
        purpose.fold(
            onSuccess = { usage ->
                current.update {
                    it.copy(
                        phase = AccountLinkPhase.EnterCode,
                        purpose = usage,
                        codeSentAt = now(),
                        busy = false,
                        error = null,
                    )
                }
            },
            onFailure = { fail((it as LinkFailure).error) },
        )
    }

    /** Usage du code envoyé, ou l'erreur à montrer. */
    private suspend fun request(address: String): Result<EmailCodePurpose> {
        // Reconnexion d'un compte e-mail sans session : jamais de compte anonyme (vecteur `009`).
        if (kind.kind.value == AccountKind.Email) return signIn(address)
        // Un compte anonyme est nécessaire pour recevoir l'adresse (premier lancement hors ligne, par exemple).
        gateway.ensureSession()
        val status = gateway.linkEmail(address)
        return when (SyncDecisions.linkEmailNextStep(status.status, status.errorCode)) {
            LinkEmailNextStep.EnterLinkCode -> Result.success(EmailCodePurpose.Link)
            LinkEmailNextStep.SignInExisting -> signIn(address)
            LinkEmailNextStep.RateLimited -> failure(AccountLinkError.RateLimited)
            LinkEmailNextStep.Retry -> failure(requestError(status))
        }
    }

    private suspend fun signIn(address: String): Result<EmailCodePurpose> {
        val status = gateway.signInWithEmail(address)
        return when {
            status.isSent -> Result.success(EmailCodePurpose.SignIn)
            status.status == HTTP_TOO_MANY_REQUESTS -> failure(AccountLinkError.RateLimited)
            else -> failure(requestError(status))
        }
    }

    /** Avant le code de connexion d'un appareil anonyme : le jeton de l'ancien compte, pour le supprimer ensuite. */
    private suspend fun rememberPreviousAccount(purpose: EmailCodePurpose) {
        if (purpose != EmailCodePurpose.SignIn || kind.kind.value != AccountKind.Anonymous) return
        previousToken = runCatching { gateway.accessToken() }.getOrNull()
        previousAccount = runCatching { gateway.sessionAccountId() }.getOrNull()
    }

    @Suppress("TooGenericExceptionCaught") // Le compte est ouvert : rien de ce qui suit ne doit l'empêcher.
    private suspend fun finish(
        account: Uuid,
        purpose: EmailCodePurpose,
    ) {
        val added =
            try {
                withTimeoutOrNull(mergeTimeout) { host.adoptAccount(account) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.i(TAG, "Reprise reportée : ${e.javaClass.simpleName}")
                null
            }
        host.sessionDidChange()
        val name = writeDisplayName(purpose)
        deletePreviousAccount(account)
        current.update {
            it.copy(
                phase = AccountLinkPhase.Done,
                busy = false,
                error = null,
                welcomeBack = purpose == EmailCodePurpose.SignIn,
                listsAdded = added ?: 0,
                displayName = name,
            )
        }
    }

    /** Le prénom saisi est écrit pour un nouveau compte, ou pour un compte existant qui n'en a pas encore. */
    private suspend fun writeDisplayName(purpose: EmailCodePurpose): String? {
        val existing = runCatching { gateway.displayName() }.getOrNull()
        val typed = pendingName
        if (typed == null || (purpose == EmailCodePurpose.SignIn && existing != null)) return existing
        return try {
            gateway.setDisplayName(typed)
            typed
        } catch (e: RemoteError) {
            Log.i(TAG, "Prénom non enregistré : ${e.message}")
            existing
        }
    }

    /** Règle 3 du §2.3 : l'ancien compte anonyme part, un échec est sans conséquence (purge à 365 jours, #68). */
    private suspend fun deletePreviousAccount(account: Uuid) {
        val token = previousToken ?: return
        val previous = previousAccount
        previousToken = null
        previousAccount = null
        if (previous == account) return
        try {
            gateway.deleteAccount(token)
            Log.i(TAG, "Ancien compte anonyme supprimé")
        } catch (e: RemoteError) {
            Log.i(TAG, "Ancien compte anonyme gardé : ${e.message}")
        }
    }

    private fun fail(error: AccountLinkError) = current.update { it.copy(error = error, busy = false) }

    private fun failure(error: AccountLinkError): Result<EmailCodePurpose> = Result.failure(LinkFailure(error))

    private class LinkFailure(
        val error: AccountLinkError,
    ) : Exception(error.wireName)

    /** Une adresse refusée par GoTrue est invalide ; une adresse sans compte (`otp_disabled`) aussi, pour l'écran. */
    private fun requestError(status: EmailCodeStatus): AccountLinkError =
        if (status.errorCode in ADDRESS_REFUSALS) AccountLinkError.InvalidEmail else AccountLinkError.Unknown

    /** GoTrue ne distingue pas un code faux d'un code expiré (`otp_expired`) : l'heure d'envoi tranche. */
    private fun codeError(
        error: RemoteError,
        sentAt: Instant?,
    ): AccountLinkError =
        when {
            error is RemoteError.Network -> {
                AccountLinkError.Offline
            }

            error is RemoteError.Server && error.code == HTTP_TOO_MANY_REQUESTS.toString() -> {
                AccountLinkError.RateLimited
            }

            error is RemoteError.Unauthorized || error is RemoteError.Server -> {
                if (sentAt != null && now() - sentAt >= CODE_LIFETIME) {
                    AccountLinkError.ExpiredCode
                } else {
                    AccountLinkError.InvalidCode
                }
            }

            else -> {
                AccountLinkError.Unknown
            }
        }

    companion object {
        private const val TAG = "AccountLink"
        const val CODE_LENGTH = 6
        private const val HTTP_TOO_MANY_REQUESTS = 429

        /** Délai avant « Renvoyer le code » (plafond `/otp` de GoTrue). */
        val RESEND_DELAY: Duration = 60.seconds

        /** Durée de validité d'un code (`otp_expiry = 900`). */
        val CODE_LIFETIME: Duration = 15.minutes

        /** La reprise des données attend au plus ce délai avant le message de fin ; elle continue sinon seule. */
        val MERGE_TIMEOUT: Duration = 20.seconds

        private const val MAX_DISPLAY_NAME = 40
        private val ADDRESS_REFUSALS = setOf("email_address_invalid", "validation_failed", "otp_disabled")

        // Même forme que celle acceptée par le serveur pour une invitation (ASCII imprimable, 87.2).
        private val EMAIL = Regex("^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$")
        private val LINK = Regex("(://|www\\.|@|/)", RegexOption.IGNORE_CASE)

        /** Adresse en minuscules, sans espace autour, ou `null` si elle n'en a pas la forme. */
        fun normalizedEmail(value: String): String? = value.trim().lowercase().takeIf { EMAIL.matches(it) }

        /**
         * Prénom accepté (`profiles.display_name`) : 1 à 40 caractères une fois rogné, sans caractère de contrôle ni de
         * mise en forme invisible (contraintes du serveur), sans adresse ni lien (« Entre 1 et 40 caractères, sans
         * adresse ni lien. »). `null` sinon.
         */
        fun cleanedDisplayName(value: String): String? {
            val name = value.trim()
            val invisible = name.any { Character.isISOControl(it) || Character.getType(it) == Character.FORMAT.toInt() }
            return name.takeIf { it.length in 1..MAX_DISPLAY_NAME && !invisible && !LINK.containsMatchIn(it) }
        }
    }
}
