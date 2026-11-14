package fr.parcourses.core.data.sync

import kotlin.time.Duration.Companion.days
import kotlin.time.Instant

/** Requête d'envoi d'un article (vecteur `001`). */
sealed interface ItemSaveRequest {
    /** Jamais arrivé au serveur : insertion complète. */
    data object Insert : ItemSaveRequest

    /** Déjà sur le serveur : mise à jour des seuls [fields] (noms de colonnes serveur, triés). */
    data class Patch(
        val fields: List<String>,
    ) : ItemSaveRequest

    /** Rien à envoyer. */
    data object None : ItemSaveRequest
}

/** Mise à jour ou suppression sans ligne (vecteur `003`). */
enum class ZeroRowOutcome(
    val wireName: String,
) {
    /** Pierre tombale : l'article a été supprimé ailleurs. Retirer l'article et l'entrée, sans réessayer. */
    DeletedElsewhere("deletedElsewhere"),

    /** Pas de pierre tombale : accès perdu ou rôle abaissé, `SyncEngine.refreshAccess`. */
    AccessLost("accessLost"),
}

/** Insertion d'un article refusée en `42501` (vecteur `004`). */
enum class InsertRefusedOutcome(
    val wireName: String,
) {
    WaitForList("waitForList"),
    RefreshAccess("refreshAccess"),
    Reconcile("reconcile"),
}

/** Liste locale vue par la réconciliation (vecteur `005`). */
data class LocalListState(
    val id: String,
    val syncedOnce: Boolean,
)

/** Listes à retirer de l'appareil, listes à descendre entièrement (vecteur `005`). Identifiants triés. */
data class ListReconciliationPlan(
    val remove: List<String>,
    val fetchFully: List<String>,
)

/** Mode de descente des suppressions (vecteur `007`). */
enum class TombstonePullMode(
    val wireName: String,
) {
    Incremental("incremental"),
    FullReconcile("fullReconcile"),
}

/** Liste locale vue par la reprise de compte (vecteur `008`). */
data class RekeyListState(
    val ownerId: String?,
    val deleted: Boolean,
    val itemCount: Int,
    val createdAt: Instant,
    val updatedAt: Instant,
)

/** Sort d'une liste à la reprise de compte (vecteur `008`). */
enum class RekeyPlan(
    val wireName: String,
) {
    /** Renvoyée au nouveau compte sous de nouveaux identifiants. */
    Resend("resend"),

    /** Liste d'un autre propriétaire : retirée de l'appareil, jamais renvoyée. */
    Drop("drop"),

    /** Supprimée localement : sa suppression s'achève. */
    Remove("remove"),

    /** Vide et jamais modifiée : retirée sans être renvoyée. */
    Skip("skip"),
}

/** Compte de l'appareil : anonyme ou lié à une adresse. Mêmes noms qu'iOS (`anonymous`, `email`). */
enum class AccountKind(
    val wireName: String,
) {
    Anonymous("anonymous"),
    Email("email"),
    ;

    companion object {
        fun fromWireName(value: String?): AccountKind? = entries.firstOrNull { it.wireName == value }
    }
}

/** Session perdue (vecteur `009`). */
enum class SessionLossAction(
    val wireName: String,
) {
    CreateAnonymous("createAnonymous"),
    WaitForSignIn("waitForSignIn"),
}

/** Suite d'une demande de liaison d'adresse (vecteur `010`). */
enum class LinkEmailNextStep(
    val wireName: String,
) {
    EnterLinkCode("enterLinkCode"),
    SignInExisting("signInExisting"),
    RateLimited("rateLimited"),
    Retry("retry"),
}

/**
 * Décisions de synchronisation, pures et partagées avec iOS (`enum SyncDecisions`) : vérifiées par les vecteurs de
 * `shared/test-vectors/sync/`, référence `shared/reference/sync.ts`. Identifiants en texte minuscule (comme la base
 * locale), sorties triées dans l'ordre des chaînes (unités UTF-16, comme `Array.prototype.sort`).
 */
object SyncDecisions {
    /** Les pierres tombales sont purgées à 30 jours : au-delà de 29, la descente incrémentale pourrait en manquer. */
    const val TOMBSTONE_SAFE_DAYS = 29

    private const val HTTP_SUCCESS_MIN = 200
    private const val HTTP_SUCCESS_MAX = 299
    private const val HTTP_UNPROCESSABLE = 422
    private const val HTTP_TOO_MANY_REQUESTS = 429

    /** Vecteur `001`. */
    fun itemSaveRequest(
        isOnServer: Boolean,
        changedFields: Collection<String>,
    ): ItemSaveRequest {
        if (!isOnServer) return ItemSaveRequest.Insert
        val fields = uniqueSorted(changedFields)
        return if (fields.isEmpty()) ItemSaveRequest.None else ItemSaveRequest.Patch(fields)
    }

    /** Vecteur `002` : une entrée remplacée garde l'union de ses champs. */
    fun mergeChangedFields(
        pending: Collection<String>?,
        new: Collection<String>,
    ): List<String> = uniqueSorted(pending.orEmpty() + new)

    /** Vecteur `003`. */
    fun zeroRowOutcome(tombstoned: Boolean): ZeroRowOutcome =
        if (tombstoned) ZeroRowOutcome.DeletedElsewhere else ZeroRowOutcome.AccessLost

    /** Vecteur `004`. */
    fun insertRefusedOutcome(
        listSynced: Boolean,
        listOwnedByMe: Boolean,
    ): InsertRefusedOutcome =
        when {
            !listSynced -> InsertRefusedOutcome.WaitForList
            listOwnedByMe -> InsertRefusedOutcome.Reconcile
            else -> InsertRefusedOutcome.RefreshAccess
        }

    /** Vecteur `005`. */
    fun reconcileLists(
        local: List<LocalListState>,
        accessible: Collection<String>,
    ): ListReconciliationPlan {
        val readable = accessible.toSet()
        val known = local.map { it.id }.toSet()
        return ListReconciliationPlan(
            remove = uniqueSorted(local.filter { it.syncedOnce && it.id !in readable }.map { it.id }),
            fetchFully = uniqueSorted(accessible.filter { it !in known }),
        )
    }

    /** Vecteur `006` : ids des articles locaux à supprimer. */
    fun applyTombstones(
        localItems: Collection<String>,
        tombstones: Collection<String>,
    ): List<String> {
        val local = localItems.toSet()
        return uniqueSorted(tombstones.filter { it in local })
    }

    /** Vecteur `007`. */
    fun tombstonePullMode(
        cursor: Instant?,
        now: Instant,
    ): TombstonePullMode {
        if (cursor == null) return TombstonePullMode.FullReconcile
        return if (now - cursor > TOMBSTONE_SAFE_DAYS.days) {
            TombstonePullMode.FullReconcile
        } else {
            TombstonePullMode.Incremental
        }
    }

    /** Vecteur `008`. `ownerId` nul : jamais descendue, donc à soi. */
    fun rekeyPlan(
        previousAccountId: String,
        list: RekeyListState,
    ): RekeyPlan =
        when {
            list.ownerId != null && list.ownerId != previousAccountId -> RekeyPlan.Drop
            list.deleted -> RekeyPlan.Remove
            list.itemCount == 0 && list.updatedAt == list.createdAt -> RekeyPlan.Skip
            else -> RekeyPlan.Resend
        }

    /** Vecteur `009`. */
    fun sessionLossAction(accountKind: AccountKind): SessionLossAction =
        if (accountKind == AccountKind.Email) SessionLossAction.WaitForSignIn else SessionLossAction.CreateAnonymous

    /** Vecteur `010`. */
    fun linkEmailNextStep(
        status: Int,
        errorCode: String?,
    ): LinkEmailNextStep =
        when {
            status in HTTP_SUCCESS_MIN..HTTP_SUCCESS_MAX -> LinkEmailNextStep.EnterLinkCode
            status == HTTP_UNPROCESSABLE && errorCode == EMAIL_EXISTS -> LinkEmailNextStep.SignInExisting
            status == HTTP_TOO_MANY_REQUESTS -> LinkEmailNextStep.RateLimited
            else -> LinkEmailNextStep.Retry
        }

    /** Code GoTrue d'une adresse déjà liée à un compte. */
    const val EMAIL_EXISTS = "email_exists"

    private fun uniqueSorted(values: Iterable<String>): List<String> = values.toSortedSet().toList()
}
