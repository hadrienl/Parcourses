package fr.parcourses.core.data.sharing

import fr.parcourses.core.model.ListRole
import java.util.Locale

/** Ce que l'interface propose selon le rôle (vecteur `002`). Le serveur reste juge (RLS). */
data class RoleCapabilities(
    val canEditItems: Boolean,
    val canShop: Boolean,
    val canShare: Boolean,
    val canManageMembers: Boolean,
    val canLeave: Boolean,
    val canRenameList: Boolean,
    val canDeleteList: Boolean,
)

/** Message de la feuille « Partager » après un refus de l'envoi (vecteur `003`). */
enum class InviteErrorKind(
    val wireName: String,
) {
    InvalidEmail("invalidEmail"),
    SelfInvitation("selfInvitation"),
    AlreadyMember("alreadyMember"),
    ListFull("listFull"),
    DailyLimit("dailyLimit"),
    PendingLimit("pendingLimit"),
    RecipientLimit("recipientLimit"),
    NotAllowed("notAllowed"),
    SignInRequired("signInRequired"),
    Offline("offline"),
    Unknown("unknown"),
}

/** État de la carte d'une invitation ouverte par son lien (vecteur `004`). */
enum class InvitationCardState(
    val wireName: String,
) {
    Acceptable("acceptable"),

    /** Envoyée à une autre adresse : acceptable après avertissement (Q4). */
    OtherAddress("otherAddress"),
    AlreadyMember("alreadyMember"),
    Used("used"),

    /** Expirée, refusée ou annulée : le même texte (on ne dit pas qu'elle a été annulée). */
    Expired("expired"),
    Invalid("invalid"),
    RateLimited("rateLimited"),
}

/** Suite d'une acceptation (vecteur `005`). [Joined] et [AlreadyMember] ouvrent la liste, après sa descente. */
enum class AcceptOutcome(
    val wireName: String,
) {
    Joined("joined"),
    AlreadyMember("alreadyMember"),
    Used("used"),
    Expired("expired"),
    Invalid("invalid"),
    RateLimited("rateLimited"),
    ;

    /** La liste est accessible : on l'ouvre. */
    val opensList: Boolean get() = this == Joined || this == AlreadyMember
}

/** Action déclenchée par un signal temps réel (vecteur `006`). */
enum class SignalAction(
    val wireName: String,
) {
    /** Descente (`pullAll`), regroupée sur 300 ms. */
    Pull("pull"),

    /** Relire `my_invitations`. */
    ReloadInvitations("reloadInvitations"),

    /** Relire `list_sharing` de la liste dont la feuille « Partager » est ouverte. */
    ReloadSharing("reloadSharing"),
}

/** Un membre connu d'une liste, pour la marque d'auteur (vecteur `008`). */
data class SharingMember(
    val userId: String,
    val displayName: String?,
)

/**
 * Décisions du partage (#87, lots 87.4 et 87.6), fonctions pures : mêmes noms, mêmes entrées et mêmes sorties qu'iOS
 * (`enum SharingDecisions`), vérifiées par les vecteurs de `shared/test-vectors/sharing/`. Référence :
 * `shared/reference/sharing.ts`.
 */
object SharingDecisions {
    private val token = Regex("^[A-Za-z0-9_-]{43}$")
    private const val SCHEME_BASE = "parcourses://invitation"
    private const val HTTPS = "https://"
    private const val INVITATION_PATH = "/i/"

    /**
     * Vecteur `001` : jeton d'un lien d'invitation (dans le fragment, 43 caractères base64url). Schéma de l'app
     * toujours ; https seulement sur [httpsHost] (comparé sans la casse), chemin `/i/`. Sinon `null`.
     */
    @Suppress("ReturnCount") // une garde par condition, comme la référence
    fun parseInvitationLink(
        url: String,
        httpsHost: String?,
    ): String? {
        val hash = url.indexOf('#')
        if (hash < 0) return null
        val base = url.substring(0, hash)
        val candidate = url.substring(hash + 1)
        if (!token.matches(candidate)) return null
        if (base == SCHEME_BASE) return candidate
        if (httpsHost == null || !base.lowercase(Locale.ROOT).startsWith(HTTPS)) return null
        val rest = base.substring(HTTPS.length)
        val slash = rest.indexOf('/')
        if (slash < 0) return null
        val host = rest.substring(0, slash)
        val path = rest.substring(slash)
        return candidate.takeIf { host.equals(httpsHost, ignoreCase = true) && path == INVITATION_PATH }
    }

    /** Vecteur `002`. */
    fun roleCapabilities(role: ListRole): RoleCapabilities {
        val owner = role == ListRole.Owner
        val writer = owner || role == ListRole.Editor
        return RoleCapabilities(
            canEditItems = writer,
            canShop = writer,
            canShare = owner,
            canManageMembers = owner,
            canLeave = !owner,
            canRenameList = owner,
            canDeleteList = owner,
        )
    }

    private val inviteErrors =
        mapOf(
            "invalid_email" to InviteErrorKind.InvalidEmail,
            "self_invitation" to InviteErrorKind.SelfInvitation,
            "already_member" to InviteErrorKind.AlreadyMember,
            "list_full" to InviteErrorKind.ListFull,
            "daily_limit" to InviteErrorKind.DailyLimit,
            "pending_limit" to InviteErrorKind.PendingLimit,
            "recipient_limit" to InviteErrorKind.RecipientLimit,
            "not allowed" to InviteErrorKind.NotAllowed,
            "unauthorized" to InviteErrorKind.SignInRequired,
        )

    /**
     * Vecteur `003` : [error] de l'Edge Function ou message de la RPC ; `null` : pas de réponse (hors ligne, délai).
     */
    fun inviteErrorKind(error: String?): InviteErrorKind =
        if (error == null) InviteErrorKind.Offline else inviteErrors[error] ?: InviteErrorKind.Unknown

    /** Vecteur `004` : `status` et `email_matches` de `preview_invitation`. */
    fun invitationCardState(
        status: String,
        emailMatches: Boolean,
    ): InvitationCardState =
        when (status) {
            "pending" -> if (emailMatches) InvitationCardState.Acceptable else InvitationCardState.OtherAddress
            "member" -> InvitationCardState.AlreadyMember
            "used" -> InvitationCardState.Used
            "expired" -> InvitationCardState.Expired
            "rate_limited" -> InvitationCardState.RateLimited
            else -> InvitationCardState.Invalid
        }

    /** Vecteur `005` : `status` de `accept_invitation`. */
    fun acceptOutcome(status: String): AcceptOutcome =
        when (status) {
            "accepted" -> AcceptOutcome.Joined
            "member" -> AcceptOutcome.AlreadyMember
            "used" -> AcceptOutcome.Used
            "expired" -> AcceptOutcome.Expired
            "rate_limited" -> AcceptOutcome.RateLimited
            else -> AcceptOutcome.Invalid
        }

    /**
     * Vecteur `006` : actions d'un signal `{ list_id, kind }`, triées par nom (ordre des unités de code, comme la
     * référence). Type inconnu : une descente.
     */
    fun signalActions(
        kind: String,
        sharingSheetOpen: Boolean,
    ): List<SignalAction> {
        val actions = mutableListOf(if (kind == "invitations") SignalAction.ReloadInvitations else SignalAction.Pull)
        if ((kind == "members" || kind == "invitations") && sharingSheetOpen) actions += SignalAction.ReloadSharing
        return actions.sortedBy { it.wireName }
    }

    /**
     * Vecteur `007` : initiale d'un membre, première lettre (point de code) du prénom sans les blancs autour, en
     * majuscule française ; sans prénom, « ? ».
     */
    fun memberInitial(displayName: String?): String {
        val trimmed = displayName.orEmpty().trim()
        if (trimmed.isEmpty()) return "?"
        val first = String(Character.toChars(trimmed.codePointAt(0)))
        return first.uppercase(Locale.FRENCH)
    }

    /**
     * Vecteur `008` : initiale de l'auteur d'un article (`updated_by`), seulement sur une liste partagée et si l'auteur
     * est un autre membre connu.
     */
    fun itemAuthorMark(
        updatedBy: String?,
        me: String,
        shared: Boolean,
        members: List<SharingMember>,
    ): String? =
        members
            .firstOrNull { shared && updatedBy != null && updatedBy != me && it.userId == updatedBy }
            ?.let { memberInitial(it.displayName) }
}
