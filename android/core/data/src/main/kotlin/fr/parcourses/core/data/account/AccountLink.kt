package fr.parcourses.core.data.account

import android.util.Log
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.LinkEmailNextStep
import fr.parcourses.core.data.sync.SyncDecisions
import fr.parcourses.core.network.AuthRequestError
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.dto.EmailCodePurpose
import fr.parcourses.core.network.dto.VerifiedCode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
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
    /** Fin du déroulé ([AccountLinkPhase.Done]). */
    val outcome: AccountLinkOutcome? = null,
    /**
     * Compte e-mail qui se reconnecte avec des modifications pas encore envoyées : elles seront perdues si l'adresse
     * est celle d'un autre compte (ses données ne lui sont jamais ajoutées).
     */
    val unsentChanges: Int = 0,
)

/** Fin de la liaison (même nom qu'iOS). */
sealed interface AccountLinkOutcome {
    /** Adresse liée au compte anonyme : même compte. */
    data object Linked : AccountLinkOutcome

    /** Connexion à un compte existant : « Bon retour », [addedLists] listes de ce téléphone ajoutées au compte (Q8). */
    data class SignedIn(
        val displayName: String?,
        val addedLists: Int,
    ) : AccountLinkOutcome
}

/** Ce que la liaison demande à l'app autour du serveur. */
interface AccountLinkHost {
    /**
     * Reprend tout de suite les données locales pour le compte [expected] de la nouvelle session
     * (`SyncEngine.adoptSessionAccount`) : nombre de listes ajoutées, `null` si la reprise attend la synchronisation.
     */
    suspend fun adoptAccount(expected: Uuid): Int?

    /** Nouvelle session : la synchronisation reprend avec une descente. */
    fun sessionDidChange()

    /** Synchronisation arrêtée pendant la vérification du code (rien ne part sous une session qui change). */
    suspend fun suspendSync()

    /** Reprise après [suspendSync]. */
    fun resumeSync()

    /** Compte auquel appartiennent les données de l'appareil (`SyncCursors.accountId`), `null` s'il est inconnu. */
    suspend fun dataAccount(): Uuid?

    /** Entrées de file pas encore envoyées. */
    suspend fun pendingChanges(): Int

    /**
     * Données de l'appareil effacées ([LocalDataPurge], mode courses fermé) : connexion d'un compte e-mail à un autre
     * compte, qui ne reçoit aucune liste du premier.
     */
    suspend fun purgeLocalData()
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
    private val switchFlag: AccountSwitchFlag = InMemoryAccountSwitchFlag(),
    private val now: () -> Instant = { Clock.System.now() },
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val lock = Mutex()
    private val current =
        MutableStateFlow(AccountLinkState(asksDisplayName = kind.kind.value == AccountKind.Anonymous))
    val state: StateFlow<AccountLinkState> = current.asStateFlow()

    private var pendingName: String? = null

    /** Changement de compte e-mail dont la purge reste à faire. */
    private var pendingSwitch: Pair<VerifiedCode, EmailCodePurpose>? = null

    /** Écriture sur le disque (préférences en `commit`) : jamais sur le fil principal. */
    private suspend fun io(write: () -> Unit) = withContext(ioDispatcher) { write() }

    /** À l'ouverture de l'écran : avertissement des modifications non envoyées d'un compte e-mail. */
    suspend fun prepare() {
        if (kind.kind.value != AccountKind.Email) return
        val pending = runCatching { host.pendingChanges() }.getOrDefault(0)
        current.update { it.copy(unsentChanges = pending) }
    }

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

    /**
     * Code saisi : validé dès le 6ᵉ chiffre par l'écran. Ni la fermeture de l'écran ni l'annulation de la tâche
     * n'interrompent la vérification et la reprise ([NonCancellable]) ; la synchronisation est reprise dans tous les
     * cas, sauf si la purge d'un changement de compte e-mail reste à faire ([retryMerge]).
     */
    suspend fun verify(code: String) =
        withContext(NonCancellable) {
            lock.withLock { verifyLocked(code) }
        }

    @Suppress("ReturnCount", "CyclomaticComplexMethod") // Une garde par cas : code, réseau, étape, refus, purge.
    private suspend fun verifyLocked(code: String) {
        val state = current.value
        val purpose = state.purpose ?: return
        if (state.phase != AccountLinkPhase.EnterCode) return
        val digits = code.filter(Char::isDigit)
        if (digits.length != CODE_LENGTH) return fail(AccountLinkError.InvalidCode)
        if (!isOnline()) return fail(AccountLinkError.Offline)
        current.update { it.copy(busy = true, error = null) }
        // Compte e-mail qui se reconnecte : ses données ne vont jamais à un autre compte.
        val fromEmail = kind.kind.value == AccountKind.Email
        val previousEmailAccount = if (fromEmail) host.dataAccount() else null
        // Rien ne part pendant que la session change : synchronisation arrêtée, reprise ensuite.
        host.suspendSync()
        var resumed = false
        try {
            // Durable : si le processus meurt, le lancement suivant rejoue la purge d'un changement de compte. Un
            // drapeau déjà posé (reprise en attente) n'est pas le nôtre : un échec ne l'efface pas.
            val setByMe = fromEmail && !switchFlag.isPending
            if (setByMe) io { switchFlag.write() }
            val verified =
                try {
                    gateway.verifyCode(state.email, digits, purpose)
                } catch (e: RemoteError) {
                    Log.i(TAG, "Code refusé : ${e.message}")
                    if (setByMe) io { switchFlag.clear() }
                    return fail(codeError(e, state.codeSentAt))
                }
            io { kind.write(AccountKind.Email) }
            current.update { it.copy(phase = AccountLinkPhase.Merging, error = null) }
            if (previousEmailAccount != null && previousEmailAccount != verified.accountId) {
                pendingSwitch = verified to purpose
                // Purge inachevée : synchronisation arrêtée, drapeau gardé, « Réessayer ».
                if (!replaceDeviceData(verified.accountId)) return failMerge()
                resumed = true
                return completeSwitch()
            }
            if (fromEmail) io { switchFlag.clear() }
            resumed = true
            host.resumeSync()
            finish(verified, purpose)
        } finally {
            if (!resumed && pendingSwitch == null) host.resumeSync()
        }
    }

    /** « Réessayer » après une purge inachevée d'un changement de compte e-mail. */
    suspend fun retryMerge() =
        withContext(NonCancellable) {
            lock.withLock {
                val switch = pendingSwitch ?: return@withLock
                current.update { it.copy(busy = true, error = null) }
                if (replaceDeviceData(switch.first.accountId)) completeSwitch() else failMerge()
            }
        }

    /** Purge faite : drapeau effacé, synchronisation reprise, puis fin du déroulé. */
    private suspend fun completeSwitch() {
        val (verified, purpose) = pendingSwitch ?: return
        pendingSwitch = null
        io { switchFlag.clear() }
        host.resumeSync()
        finish(verified, purpose)
    }

    private fun failMerge() = current.update { it.copy(busy = false, error = AccountLinkError.Unknown) }

    /**
     * Compte e-mail A vers un autre compte B : aucune liste de A n'est renvoyée à B. L'appareil est purgé, puis B est
     * adopté sans reprise ; la descente apporte ses listes.
     */
    @Suppress("TooGenericExceptionCaught") // Toute panne locale arrête le déroulé, synchronisation suspendue.
    private suspend fun replaceDeviceData(account: Uuid): Boolean =
        try {
            host.purgeLocalData()
            // La purge efface `account.kind` : c'est toujours un compte e-mail.
            io { kind.write(AccountKind.Email) }
            gateway.acknowledgeAccount(account)
            Log.i(TAG, "Autre compte e-mail : données de l'appareil remplacées")
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Données de l'appareil non remplacées : ${e.javaClass.simpleName}")
            false
        }

    private suspend fun send(address: String) {
        if (!isOnline()) return fail(AccountLinkError.Offline)
        current.update { it.copy(busy = true, error = null) }
        val purpose =
            try {
                request(address)
            } catch (e: RemoteError) {
                Log.i(TAG, "Code non envoyé : ${e.message}")
                return fail(requestError(e))
            }
        current.update {
            it.copy(
                phase = AccountLinkPhase.EnterCode,
                purpose = purpose,
                codeSentAt = now(),
                busy = false,
                error = null,
            )
        }
    }

    /** Usage du code envoyé. Un refus lève [AuthRequestError], classé par [requestError]. */
    private suspend fun request(address: String): EmailCodePurpose {
        // Reconnexion d'un compte e-mail sans session : jamais de compte anonyme (vecteur `009`).
        if (kind.kind.value == AccountKind.Email) return signIn(address)
        // Un compte anonyme est nécessaire pour recevoir l'adresse (premier lancement hors ligne, par exemple).
        gateway.ensureSession()
        val refusal =
            try {
                gateway.linkEmail(address)
                null
            } catch (e: AuthRequestError) {
                e
            }
        return when (SyncDecisions.linkEmailNextStep(refusal?.status ?: HTTP_OK, refusal?.code)) {
            LinkEmailNextStep.EnterLinkCode -> EmailCodePurpose.Link
            LinkEmailNextStep.SignInExisting -> signIn(address)
            LinkEmailNextStep.RateLimited, LinkEmailNextStep.Retry -> throw checkNotNull(refusal)
        }
    }

    private suspend fun signIn(address: String): EmailCodePurpose {
        gateway.signInWithEmail(address)
        return EmailCodePurpose.SignIn
    }

    @Suppress("TooGenericExceptionCaught") // Le compte est ouvert : rien de ce qui suit ne doit l'empêcher.
    private suspend fun finish(
        verified: VerifiedCode,
        purpose: EmailCodePurpose,
    ) {
        // Sans délai : la reprise va au bout (« Rapprochement de vos listes… » reste affiché pendant ce temps).
        val added =
            try {
                host.adoptAccount(verified.accountId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.i(TAG, "Reprise reportée : ${e.javaClass.simpleName}")
                null
            }
        host.sessionDidChange()
        val name = writeDisplayName(purpose)
        verified.previousAnonymousToken?.let { deletePreviousAccount(it) }
        val outcome =
            when (purpose) {
                EmailCodePurpose.Link -> AccountLinkOutcome.Linked
                EmailCodePurpose.SignIn -> AccountLinkOutcome.SignedIn(name, added ?: 0)
            }
        current.update { it.copy(phase = AccountLinkPhase.Done, busy = false, error = null, outcome = outcome) }
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
    private suspend fun deletePreviousAccount(token: String) {
        try {
            gateway.deleteAccount(token)
            Log.i(TAG, "Ancien compte anonyme supprimé")
        } catch (e: RemoteError) {
            Log.i(TAG, "Ancien compte anonyme gardé : ${e.message}")
        }
    }

    private fun fail(error: AccountLinkError) = current.update { it.copy(error = error, busy = false) }

    /** Refus d'une demande de code : trop de demandes, adresse refusée (ou sans compte), réseau. */
    private fun requestError(error: RemoteError): AccountLinkError =
        when {
            error is AuthRequestError && error.status == HTTP_TOO_MANY_REQUESTS -> AccountLinkError.RateLimited
            error is AuthRequestError && error.code in ADDRESS_REFUSALS -> AccountLinkError.InvalidEmail
            error is RemoteError.Network -> AccountLinkError.Offline
            else -> AccountLinkError.Unknown
        }

    /** GoTrue ne distingue pas un code faux d'un code expiré (`otp_expired`) : l'heure d'envoi tranche. */
    private fun codeError(
        error: RemoteError,
        sentAt: Instant?,
    ): AccountLinkError =
        when {
            error is RemoteError.Network -> {
                AccountLinkError.Offline
            }

            error is AuthRequestError && error.status == HTTP_TOO_MANY_REQUESTS -> {
                AccountLinkError.RateLimited
            }

            error is AuthRequestError && error.status in HTTP_CLIENT_ERRORS -> {
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
        private const val HTTP_OK = 200
        private const val HTTP_TOO_MANY_REQUESTS = 429
        private const val HTTP_CLIENT_MIN = 400
        private const val HTTP_CLIENT_MAX = 499
        private val HTTP_CLIENT_ERRORS = HTTP_CLIENT_MIN..HTTP_CLIENT_MAX

        /** Délai avant « Renvoyer le code » (plafond `/otp` de GoTrue). */
        val RESEND_DELAY: Duration = 60.seconds

        /** Durée de validité d'un code (`otp_expiry = 900`). */
        val CODE_LIFETIME: Duration = 15.minutes

        private const val MAX_DISPLAY_NAME = 40

        /** Adresse refusée par GoTrue ; `otp_disabled` : aucun compte pour cette adresse (même liste qu'iOS). */
        private val ADDRESS_REFUSALS =
            setOf(
                "email_address_invalid",
                "validation_failed",
                "otp_disabled",
                "email_address_not_authorized",
                "signup_disabled",
            )

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
