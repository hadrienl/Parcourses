package fr.parcourses.app

import android.content.Context
import android.util.Log
import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.data.EntryAnalyzer
import fr.parcourses.core.data.account.AccountDeletion
import fr.parcourses.core.data.account.AccountDeletionFlag
import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.data.account.AccountKindFlag
import fr.parcourses.core.data.account.AccountLink
import fr.parcourses.core.data.account.AccountLinkHost
import fr.parcourses.core.data.account.AccountSession
import fr.parcourses.core.data.account.AccountSignOut
import fr.parcourses.core.data.account.AccountSignOutFlag
import fr.parcourses.core.data.account.AccountSwitchFlag
import fr.parcourses.core.data.account.AccountSwitchReplay
import fr.parcourses.core.data.account.ContinueWithoutAccount
import fr.parcourses.core.data.account.DeletionGuardedGateway
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.account.SharedPreferencesAccountDeletionFlag
import fr.parcourses.core.data.account.SharedPreferencesAccountKindFlag
import fr.parcourses.core.data.account.SharedPreferencesAccountSignOutFlag
import fr.parcourses.core.data.account.SharedPreferencesAccountSwitchFlag
import fr.parcourses.core.data.repository.CategoryRepository
import fr.parcourses.core.data.repository.GraphRepository
import fr.parcourses.core.data.repository.ListRepository
import fr.parcourses.core.data.repository.ProductRepository
import fr.parcourses.core.data.repository.RoomCategoryRepository
import fr.parcourses.core.data.repository.RoomGraphRepository
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.repository.RoomProductRepository
import fr.parcourses.core.data.repository.RoomStoreRepository
import fr.parcourses.core.data.repository.RoomVisitRepository
import fr.parcourses.core.data.repository.StoreRepository
import fr.parcourses.core.data.repository.VisitRepository
import fr.parcourses.core.data.sharing.RealtimeSignals
import fr.parcourses.core.data.sharing.SharingNotices
import fr.parcourses.core.data.sharing.SharingRepository
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.data.sync.NetworkMonitor
import fr.parcourses.core.data.sync.PulledItemClassification
import fr.parcourses.core.data.sync.SharedPreferencesSyncCursors
import fr.parcourses.core.data.sync.SyncCoordinator
import fr.parcourses.core.data.sync.SyncCursors
import fr.parcourses.core.data.sync.SyncDependencies
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.data.sync.WorkManagerSyncScheduler
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.location.LocationProvider
import fr.parcourses.core.location.SystemLocationProvider
import fr.parcourses.core.network.AuthBootstrap
import fr.parcourses.core.network.InvitationLinks
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.SessionMaintenance
import fr.parcourses.core.network.SupabaseConfig
import fr.parcourses.core.network.SupabaseGateway
import fr.parcourses.core.network.createSupabaseGateway
import fr.parcourses.feature.shopping.GraphSnapshotCache
import fr.parcourses.feature.shopping.ShoppingDependencies
import fr.parcourses.feature.shopping.ShoppingTimings
import fr.parcourses.feature.shopping.live.LiveUpdatePreferences
import fr.parcourses.feature.shopping.live.SharedPreferencesLiveUpdatePreferences
import fr.parcourses.feature.shopping.live.ShoppingLiveUpdates
import fr.parcourses.feature.shopping.live.SystemLiveUpdateNotifier
import fr.parcourses.feature.storepicker.LocationPermissionMemory
import fr.parcourses.feature.storepicker.SharedPreferencesLocationPermissionMemory
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Dispatchers.IO
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.uuid.Uuid

/** Ce qu'un compte anonyme voulait faire avant d'être invité à se connecter (#87). */
sealed interface AfterSignIn {
    /** « Partager » sur une liste. */
    data class Share(
        val listId: String,
    ) : AfterSignIn

    /** Un lien d'invitation, dont le jeton reste dans [AppContainer.pendingInvitation]. */
    data object Invitation : AfterSignIn
}

/** Visite ouverte que l'app rouvre au lancement. */
data class ResumableVisit(
    val listId: String,
    val storeId: String,
    val visitId: String,
)

/**
 * Racine de l'injection, à la main (une seule instance par processus). Tout est créé à la demande : rien
 * n'ouvre la base ni le réseau avant le premier usage. Sans configuration Supabase, [engine] est `null` et l'app
 * reste entièrement locale (la file d'envoi se remplit, rien ne part).
 */
@Suppress("TooManyFunctions")
class AppContainer(
    private val context: Context,
    private val config: SupabaseConfig? =
        SupabaseConfig.create(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_PUBLISHABLE_KEY),
    /** Ouverture de la base : celle de l'app, ou une base en mémoire pour les tests. */
    private val openDatabase: (Context) -> ParcoursesDatabase = { ParcoursesDatabaseFactory.create(it, IO) },
) {
    val database: ParcoursesDatabase by lazy { openDatabase(context) }

    /** Drapeau durable de « Supprimer mes données » (#68) : tant qu'il existe, ni synchronisation ni compte créé. */
    val deletionFlag: AccountDeletionFlag by lazy { SharedPreferencesAccountDeletionFlag(context) }

    /** Drapeau durable de « Se déconnecter » (#87) : la purge est rejouée au lancement tant qu'il existe. */
    val signOutFlag: AccountSignOutFlag by lazy { SharedPreferencesAccountSignOutFlag(context) }

    /** Drapeau durable `account.switch` (#87) : changement de compte e-mail en cours, rejoué au lancement. */
    val switchFlag: AccountSwitchFlag by lazy { SharedPreferencesAccountSwitchFlag(context) }

    /** Drapeau durable `account.kind` (#87) : un compte e-mail sans session attend la reconnexion. */
    val accountKind: AccountKindFlag by lazy { SharedPreferencesAccountKindFlag(context) }

    /**
     * Liens d'invitation (#87) : hôte https de la configuration de build (`parcourses.invitationHost`), vide par
     * défaut jusqu'aux App Links du lot 87.7 ; seul le schéma `parcourses://` est alors reconnu.
     */
    val invitationLinks: InvitationLinks = InvitationLinks(BuildConfig.INVITATION_HOST)

    private val supabase: SupabaseGateway? by lazy {
        config?.let {
            createSupabaseGateway(
                context,
                it,
                invitationLinks,
            )
        }
    }

    /**
     * Toute l'app passe par la garde : aucun `ensureSession` pendant une suppression du compte, et jamais de compte
     * anonyme recréé pour un compte e-mail (#87).
     */
    val gateway: RemoteGateway? by lazy {
        supabase?.let { DeletionGuardedGateway(it, deletionFlag, accountKind, signOutFlag) }
    }

    /** Entretien de la session (écran À propos) : `null` sans configuration Supabase. */
    val sessionMaintenance: SessionMaintenance? get() = supabase

    val scheduler by lazy { WorkManagerSyncScheduler(context) }

    /** Réseau observable (bandeau hors ligne d'une liste partagée). */
    val isOnline: StateFlow<Boolean> get() = networkMonitor.onlineState

    private val networkMonitor by lazy { NetworkMonitor(context, onReturn = { coordinator?.requestSync(pull = true) }) }
    private val networkStarted = AtomicBoolean(false)

    private val cursors: SyncCursors by lazy { SharedPreferencesSyncCursors(context) }

    /**
     * Tout ce qui garde un état en mémoire lié au compte : le moteur (curseurs en cours, `remapHistory`, délais), son
     * coordinateur, la Live Update (`current`, `posted`) et le mode courses qui la porte. [reset] les recrée.
     */
    private inner class Session {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

        val engine: SyncEngine? by lazy {
            gateway?.let { remote ->
                SyncEngine(
                    gateway = remote,
                    db = database,
                    cursors = cursors,
                    classify = pulledItemClassifier(),
                    dependencies =
                        SyncDependencies(
                            isOnline = { networkMonitor.isOnline },
                            // Suppression du compte (#68) ou déconnexion (#87) en cours : aucune passe.
                            isAccountDeletionPending = {
                                deletionFlag.isPending || signOutFlag.isPending || switchFlag.isPending
                            },
                            accountKind = { accountKind.kind.value },
                            // Liste retirée, accès abaissé ou remonté par un autre membre (#87, lot 87.6).
                            onAccessChange = sharingNotices::post,
                        ),
                )
            }
        }

        val coordinator: SyncCoordinator? by lazy { engine?.let { SyncCoordinator(it, scheduler) } }

        val liveUpdates: ShoppingLiveUpdates by lazy {
            ShoppingLiveUpdates(
                notifier = notifier,
                visits = visits,
                lists = lists,
                analyzer = analyzer,
                preferences = livePreferences,
                scope = scope,
                remaps = remaps,
            )
        }

        val shopping: ShoppingDependencies by lazy {
            ShoppingDependencies(
                lists,
                visits,
                stores,
                categories,
                analyzer,
                GraphSnapshotCache(graphs, gateway),
                liveUpdates,
                // Liste partagée (#87, lot 87.6) : qui a coché quoi, et l'accès perdu qui arrête les courses.
                participants = { listId -> database.participants().get(listId) },
                accessNotices = sharingNotices.notices,
            )
        }

        fun close() = scope.cancel()
    }

    @Volatile
    private var session = Session()

    /** Augmente à chaque [reset] : la navigation et les flux qui suivent le moteur courant s'y abonnent. */
    private val sessionGeneration = MutableStateFlow(0)
    val generation: StateFlow<Int> = sessionGeneration.asStateFlow()

    private val navigationReset = AtomicBoolean(false)

    val engine: SyncEngine? get() = session.engine

    val coordinator: SyncCoordinator? get() = session.coordinator

    /**
     * Reprises de compte du moteur courant, y compris après un [reset] : les écrans et la Live Update s'abonnent ici
     * une fois pour toutes.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    val remaps: Flow<IdentifierRemap> = sessionGeneration.flatMapLatest { session.engine?.remaps ?: emptyFlow() }

    /** Session perdue du moteur courant, y compris après un [reset]. */
    @OptIn(ExperimentalCoroutinesApi::class)
    private val waitsForSession: Flow<Boolean> =
        sessionGeneration.flatMapLatest { session.engine?.waitsForSession ?: flowOf(false) }

    /** Compte de l'appareil pour les écrans (#87) : type, adresse, prénom, session perdue. */
    val accountSession: AccountSession by lazy { AccountSession(gateway, accountKind, waitsForSession) }

    /** Une liaison par écran de connexion ; `null` sans Supabase. */
    fun newAccountLink(): AccountLink? =
        gateway?.let { remote ->
            AccountLink(
                remote,
                accountKind,
                LinkHost(),
                isOnline = { networkMonitor.isOnline },
                switchFlag = switchFlag,
                accountLock = accountLock,
            )
        }

    /** Ce que la liaison demande à la synchronisation : reprise immédiate des données, puis descente. */
    private inner class LinkHost : AccountLinkHost {
        override suspend fun adoptAccount(expected: Uuid): Int? = engine?.adoptSessionAccount(expected)

        override fun sessionDidChange() {
            accountSession.forget()
            notifySessionChange()
        }

        override suspend fun suspendSync() {
            coordinator?.suspend()
        }

        // Comme `DeletionHost.resumeSync` : Live Update, travail périodique, moteur relancé avec une descente.
        override fun resumeSync() = DeletionHost().resumeSync()

        override suspend fun dataAccount(): Uuid? = withContext(IO) { cursors.accountId }

        override suspend fun pendingChanges(): Int = database.outbox().all().size

        override suspend fun adoptDataAccount(account: Uuid) =
            withContext(IO) { cursors.adopt(account, AccountKind.Email) }

        override suspend fun purgeLocalData() {
            val host = DeletionHost()
            host.endShopping()
            purge.run()
            // Pas de `reset()` : l'écran de connexion reste ouvert. Le moteur, arrêté, relit les curseurs effacés.
            host.clearLocalState()
        }
    }

    /** Une nouvelle entrée de file réveille la synchronisation. */
    val lists: ListRepository by lazy { RoomListRepository(database, onEnqueue = { coordinator?.requestSync() }) }
    val products: ProductRepository by lazy { RoomProductRepository(database) }
    val categories: CategoryRepository by lazy { RoomCategoryRepository(database) }
    val analyzer: EntryAnalyzer by lazy { EntryAnalyzer() }
    val stores: StoreRepository by lazy { RoomStoreRepository(database) }

    /** Position ponctuelle : Google Play Services, sinon le gestionnaire du système (API 30+). */
    val location: LocationProvider by lazy { SystemLocationProvider(context) }

    /** Refus définitif de la localisation, retenu d'une ouverture du choix du magasin à l'autre. */
    val locationPermission: LocationPermissionMemory by lazy { SharedPreferencesLocationPermissionMemory(context) }

    val visits: VisitRepository by lazy { RoomVisitRepository(database, onEnqueue = { coordinator?.requestSync() }) }
    val graphs: GraphRepository by lazy { RoomGraphRepository(database) }

    /** Tout ce que le mode courses lit et écrit (instantané du graphe compris). */
    val shopping: ShoppingDependencies get() = session.shopping

    val livePreferences: LiveUpdatePreferences by lazy { SharedPreferencesLiveUpdatePreferences(context) }

    private val notifier by lazy { SystemLiveUpdateNotifier(context) }

    /**
     * Live Update du mode courses : **une seule instance** à la fois, pour l'écran comme pour le receiver. Recréée
     * par [reset] après une suppression des données.
     */
    val liveUpdates: ShoppingLiveUpdates get() = session.liveUpdates

    private val deepLinks = Channel<String>(Channel.BUFFERED)

    /** Visites demandées par la Live Update (`parcourses://shopping/<id>`) : un seul collecteur, toujours composé. */
    val shoppingLinks: Flow<String> = deepLinks.receiveAsFlow()

    fun offerShoppingLink(visitId: String) {
        deepLinks.trySend(visitId)
    }

    /**
     * Visite à rouvrir pour un lien de la Live Update : seulement si c'est la visite ouverte et encore active (mêmes
     * règles qu'au lancement, voir [resumableVisit]). Sinon la notification, périmée, est retirée.
     */
    suspend fun linkedVisit(visitId: String): ResumableVisit? {
        // Suppression des données en cours : aucun mode courses ne se rouvre.
        if (accountDeletion.state.value != AccountDeletionState.Idle) return null
        val visit = resumableVisit()
        liveUpdates.reconcile()
        return visit?.takeIf { it.visitId == visitId }
    }

    private val storeChoiceEvents = StoreChoiceEvents()

    /** Choix de magasin à consommation unique : voir [StoreChoiceEvents] pour le contrat du collecteur. */
    val storeChoices: Flow<StoreChoice> get() = storeChoiceEvents.choices

    fun offerStoreChoice(choice: StoreChoice) = storeChoiceEvents.offer(choice)

    /** Reprise de la visite ouverte : une fois par processus, au lancement à froid (voir [LaunchResume]). */
    val launchResume = LaunchResume()

    /**
     * Visite ouverte à reprendre au lancement, vérifiée. Sa liste a pu disparaître, ou elle est restée sans coche
     * depuis plus de [expiry] : elle est alors abandonnée (close à sa dernière coche, supprimée si elle n'en a
     * aucune et n'est jamais partie, ses introuvables remis à acheter : voir `VisitRepository.abandonVisit`) et rien
     * n'est rouvert.
     * L'abandon ne lève rien sur une visite disparue entre-temps (reprise de compte) : le lancement ne plante pas,
     * et une visite redevenue active entre la lecture et l'abandon reste ouverte.
     */
    suspend fun resumableVisit(expiry: Duration = ShoppingTimings().expiry): ResumableVisit? {
        // Suppression interrompue : la visite va être effacée, elle n'est pas rouverte (ni abandonnée vers le serveur).
        // Le drapeau est lu sur le disque : jamais sur le fil principal, d'où vient la reprise au lancement.
        val pending = withContext(IO) { deletionFlag.isPending }
        val visit = (if (pending) null else visits.openVisit()) ?: return null
        val now = Clock.System.now()
        val last = visits.lastActivity(visit.id) ?: visit.startedAt
        val listExists = lists.list(visit.listId) != null
        val usable = listExists && now - last < expiry
        // Liste disparue : abandon sans condition. Sinon seulement si la visite est encore périmée dans la transaction.
        if (!usable) visits.abandonVisit(visit.id, now, staleAfter = if (listExists) expiry else Duration.ZERO)
        return if (usable) ResumableVisit(visit.listId, visit.storeId, visit.id) else null
    }

    /**
     * Lancement : catégories, connexion anonyme, puis synchronisation (en tâche de fond). Si une suppression des
     * données a été interrompue (drapeau présent), ni synchronisation ni connexion : elle reprend d'abord.
     */
    fun start(scope: CoroutineScope) {
        scope.launch {
            categories.seedIfNeeded()
            if (gateway != null) startNetworkMonitor()
            if (accountDeletion.resumeAtLaunch()) return@launch
            // Déconnexion interrompue (#87) : la purge reprend, voile affiché.
            if (accountSignOut?.resumeAtLaunch() == true) return@launch
            // Une Live Update restée d'un lancement précédent ne survit que si sa visite est encore ouverte.
            liveUpdates.reconcile()
            gateway?.let { remote ->
                withContext(IO) { inferAccountKind(remote) }
                replayAccountSwitch()
                coordinator?.start()
                // Un échec n'empêche rien : tout est local et la file attend.
                AuthBootstrap.signIn(remote)
                notifySessionChange()
            }
        }
    }

    private fun startNetworkMonitor() {
        if (networkStarted.compareAndSet(false, true)) networkMonitor.start()
    }

    /** Suites réseau des actions d'entretien : elles survivent à l'écran qui les a lancées. */
    private val maintenanceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** « Supprimer mes données » (#68 §5.3) : voir [AccountDeletion]. */
    val accountDeletion: AccountDeletionController by lazy {
        AccountDeletionController(
            AccountDeletion(
                gateway = gateway,
                flag = deletionFlag,
                purge = purge,
                host = DeletionHost(),
                isOnline = { networkMonitor.isOnline },
            ),
            maintenanceScope,
        )
    }

    /** Purge locale (#68), commune à la suppression et à la déconnexion : `account.kind` compris. */
    private val purge by lazy {
        LocalDataPurge(database, cursors, accountKind = accountKind, switchFlag = switchFlag)
    }

    /** « Se déconnecter » (#87 §2.4) : `null` sans Supabase. */
    val accountSignOut: AccountSignOutController? by lazy {
        gateway?.let { remote ->
            AccountSignOutController(
                AccountSignOut(
                    gateway = remote,
                    purge = purge,
                    host = DeletionHost(),
                    flag = signOutFlag,
                    isOnline = { networkMonitor.isOnline },
                    flush = { engine?.drain() },
                    // `PENDING` et `FAILED` : toute entrée encore là sera perdue.
                    unsent = { database.outbox().all().size },
                ),
                maintenanceScope,
            )
        }
    }

    /**
     * « Continuer sans compte » (compte e-mail sans session, confirmé) : compte anonyme neuf, puis la synchronisation
     * reprend les données de l'appareil (les listes partagées avec soi en partent, `AccountRekey`).
     */
    fun continueWithoutAccount() {
        val remote = gateway ?: return
        maintenanceScope.launch {
            // Toute panne (purge, SQLite, réseau) reprend la synchronisation, sans planter ce scope.
            ContinueWithoutAccount(remote, purge, DeletionHost(), forget = accountSession::forget).run()
        }
    }

    /** `account.kind` absent (installation d'avant #87) avec une session non anonyme : compte e-mail. */
    private suspend fun inferAccountKind(remote: RemoteGateway) {
        if (accountKind.isSet) return
        val email = runCatching { remote.accountEmail() }.getOrNull()
        if (email != null) accountKind.write(AccountKind.Email)
    }

    /** Verrou de compte : reprise d'un changement de compte et vérification d'un code ne se chevauchent jamais. */
    private val accountLock = Mutex()

    /** Reprise d'un changement de compte e-mail interrompu (`account.switch`) : voir [AccountSwitchReplay]. */
    private val switchReplay: AccountSwitchReplay? by lazy {
        gateway?.let { remote ->
            AccountSwitchReplay(remote, switchFlag, cursors, accountKind, accountLock) {
                withTimeoutOrNull(LIVE_UPDATE_BUDGET) { liveUpdates.endAll().await() }
                purge.run()
                livePreferences.clear()
            }
        }
    }

    /** Vrai si plus rien n'est à reprendre. Lit et écrit le disque : jamais sur le fil principal. */
    internal suspend fun replayAccountSwitch(): Boolean = withContext(IO) { switchReplay?.run() ?: true }

    /** Build sans Supabase : la suppression ne purge que l'appareil (§5.7). */
    val isLocalOnly: Boolean get() = config == null

    /**
     * Recrée tout ce qui a un état en mémoire ([Session]) et demande à la navigation de repartir sur les listes, pile
     * vidée. Le moteur et la Live Update d'avant sont arrêtés pour de bon.
     */
    fun reset() {
        val old = session
        session = Session()
        navigationReset.set(true)
        sessionGeneration.update { it + 1 }
        old.close()
    }

    /** `true` une fois après chaque [reset] : la navigation vide alors sa pile. */
    fun consumeNavigationReset(): Boolean = navigationReset.getAndSet(false)

    /** Ce que la suppression demande à l'app, étape par étape. */
    private inner class DeletionHost : AccountDeletionHost {
        override suspend fun suspendSync() {
            // Sans Supabase, ni moteur ni travaux.
            coordinator?.suspend()
        }

        override suspend fun endShopping() {
            // Le mode courses se ferme dans la navigation (voile affiché), sans `closeVisit` : la visite sera effacée.
            val ended = withTimeoutOrNull(LIVE_UPDATE_BUDGET) { liveUpdates.endAll().await() }
            // Boucle de la Live Update bloquée : la notification part quand même.
            if (ended == null) notifier.cancel()
        }

        override suspend fun clearLocalState() {
            // Base vidée : une notification reposée entre-temps part, puis les préférences. Un échec lève (doute).
            notifier.cancel()
            livePreferences.clear()
            sharingNotices.clear()
        }

        override fun resumeSync() {
            liveUpdates.resume()
            // `sessionDidChange` relance le moteur (`SyncEngine.resume`) puis une passe avec descente.
            coordinator?.start()
            notifySessionChange()
        }

        override suspend fun rebuild() {
            reset()
            // La nouvelle instance retire toute notification sans visite ouverte (il n'y en a plus).
            liveUpdates.reconcile()
            coordinator?.start()
            notifySessionChange()
        }
    }

    /**
     * « Réinitialiser la session » : session oubliée, puis, en tâche de fond, nouveau compte anonyme et
     * synchronisation, qui réidentifie les données locales pour ce compte (voir [SessionMaintenance.resetSession]).
     * @return `false` si la clé s'ouvre de nouveau : rien n'a été oublié.
     * @throws fr.parcourses.core.network.RemoteError si la session n'a pas pu être oubliée.
     */
    suspend fun resetSession(): Boolean {
        val reset = sessionMaintenance?.resetSession() == true
        if (reset) {
            maintenanceScope.launch {
                // Hors ligne, la connexion échoue sans bruit : la synchronisation la retentera.
                gateway?.let { AuthBootstrap.signIn(it) }
                notifySessionChange()
            }
        }
        return reset
    }

    /**
     * La session a changé (connexion, déconnexion, compte recréé) : le moteur reprend avec une descente, et le canal
     * temps réel est rouvert pour le compte de la nouvelle session.
     */
    private fun notifySessionChange() {
        coordinator?.sessionDidChange()
        realtime?.sessionChanged()
    }

    // region Partage (#87, lot 87.6)

    /** Messages d'accès à montrer (liste retirée, lecture seule), en mémoire. */
    val sharingNotices = SharingNotices()

    /** Partage d'une liste : réseau exigé, rien en file ; `null` sans Supabase. */
    val sharing: SharingRepository? by lazy {
        gateway?.let { remote ->
            SharingRepository(
                remote,
                database,
                isOnline = { networkMonitor.isOnline },
                // Accès gagné : la liste est descendue entièrement avant d'être ouverte.
                pull = { engine?.drain(pull = true) },
            )
        }
    }

    /**
     * Signaux temps réel (#87 §6.2) : canal `user:<uid>` d'un compte e-mail, ouvert au premier plan seulement
     * (`ProcessLifecycleOwner`, voir [ParcoursesApp]). Un signal demande une descente ; les écrans du partage
     * s'abonnent à ses relectures.
     */
    val realtime: RealtimeSignals? by lazy {
        val source = supabase ?: return@lazy null
        val remote = gateway ?: return@lazy null
        RealtimeSignals(
            source = source,
            accountId = { remote.currentAccountId() },
            accountKind = accountKind.kind,
            requestPull = { coordinator?.requestSync(pull = true) },
            scope = maintenanceScope,
        )
    }

    /** Jeton d'une invitation ouverte par son lien : en mémoire seulement, jamais écrit sur le disque (#87 §1.3). */
    @Volatile
    var pendingInvitation: String? = null
        private set

    private val invitationEvents = Channel<String>(Channel.BUFFERED)

    /** Liens d'invitation reçus par l'activité : un seul collecteur, la navigation. */
    val invitationLinkOpenings: Flow<String> = invitationEvents.receiveAsFlow()

    fun offerInvitation(token: String) {
        pendingInvitation = token
        invitationEvents.trySend(token)
    }

    /** L'invitation a été traitée (acceptée, refusée, fermée) : le jeton est oublié. */
    fun forgetInvitation() {
        pendingInvitation = null
    }

    /** Action demandée par un compte anonyme, reprise après la connexion (#87 §1.1) : en mémoire seulement. */
    @Volatile
    var afterSignIn: AfterSignIn? = null

    // endregion

    /** Premier plan : une passe avec descente. */
    fun onForeground() {
        // Changement de compte e-mail pas encore repris (session illisible au lancement) : nouvel essai.
        if (gateway != null) {
            maintenanceScope.launch {
                // Drapeau lu hors du fil principal ; la reprise attend une vérification de code en cours (verrou).
                val pending = withContext(IO) { switchFlag.isPending }
                if (pending && replayAccountSwitch()) notifySessionChange()
            }
        }
        coordinator?.requestSync(pull = true)
    }

    private fun pulledItemClassifier(): (String) -> PulledItemClassification {
        val classifier = CategoryClassifier()
        return { label -> classifier.classify(label).let { PulledItemClassification(it.normalized, it.categoryId) } }
    }

    private companion object {
        const val TAG = "AppContainer"
        val LIVE_UPDATE_BUDGET = 3.seconds
    }
}
