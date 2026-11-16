package fr.parcourses.app

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import fr.parcourses.core.data.account.AccountEntry
import fr.parcourses.core.data.account.AccountState
import fr.parcourses.core.data.sharing.AccessChange
import fr.parcourses.core.data.sharing.InviteErrorKind
import fr.parcourses.core.data.sharing.SharingFailure
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.feature.lists.InvitationLinkRoute
import fr.parcourses.feature.lists.InvitationLinkViewModel
import fr.parcourses.feature.lists.InvitationsViewModel
import fr.parcourses.feature.lists.ListDetailRoute
import fr.parcourses.feature.lists.ListDetailViewModel
import fr.parcourses.feature.lists.ListSharingSources
import fr.parcourses.feature.lists.ListsAccountUi
import fr.parcourses.feature.lists.ListsInvitationsUi
import fr.parcourses.feature.lists.ListsRoute
import fr.parcourses.feature.lists.ListsViewModel
import fr.parcourses.feature.lists.ReceivedInvitationsRoute
import fr.parcourses.feature.lists.ShareListRoute
import fr.parcourses.feature.lists.ShareListViewModel
import fr.parcourses.feature.shopping.ShoppingRoute
import fr.parcourses.feature.shopping.ShoppingSummaryRoute
import fr.parcourses.feature.shopping.ShoppingViewModel
import fr.parcourses.feature.shopping.live.NotificationPermissionPrompt
import fr.parcourses.feature.storepicker.StorePickerRoute
import fr.parcourses.feature.storepicker.StorePickerViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.map

/**
 * Une seule activité, une pile de routes, un ViewModel par entrée. [coldStart] : l'activité démarre sans état
 * sauvegardé (ni recréation ni restauration après la mort du processus). Une entrée par route : la longueur et les
 * branches viennent de la table des écrans, pas d'une logique imbriquée.
 */
@Suppress("LongMethod", "CyclomaticComplexMethod")
@Composable
fun ParcoursesNavHost(
    container: AppContainer,
    coldStart: Boolean = false,
) {
    val backStack = rememberNavBackStack(routeConfiguration, Route.Lists)
    // Clé de session illisible : pastille sur À propos, qui propose de réinitialiser la session (#51).
    val sessionStuckFlow = remember(container) { container.sessionMaintenance?.isSessionStorageStuck ?: NotStuck }

    val deletion by container.accountDeletion.state.collectAsState()
    val signOutFlow = remember(container) { container.accountSignOut?.state ?: NoSignOut }
    val signOut by signOutFlow.collectAsState()

    // Reprise de compte : les écrans ouverts suivent leurs nouveaux identifiants.
    LaunchedEffect(container) {
        container.remaps.collect { remap ->
            backStack.applyRemap(remap)
        }
    }

    // Données supprimées (#68) : l'état de l'app a été recréé, la navigation repart sur les listes, pile vidée.
    LaunchedEffect(container) {
        container.generation.collect { if (container.consumeNavigationReset()) backStack.resetToLists() }
    }

    // Suppression en cours : le mode courses se ferme, sans `closeVisit` (la visite va être effacée).
    LaunchedEffect(deletion) {
        if (deletion == AccountDeletionState.Running) backStack.closeShopping()
    }

    // Déconnexion (#87) : même chose, les données de l'appareil vont être effacées.
    LaunchedEffect(signOut) {
        if (signOut == AccountSignOutState.Running) backStack.closeShopping()
    }

    // Choix du magasin : le collecteur est ici car cette composition ne quitte jamais l'écran (voir `storeChoices`).
    LaunchedEffect(container) {
        container.storeChoices.collect { choice -> backStack.openShopping(choice) }
    }

    // Reprise au lancement d'une visite restée ouverte : une fois par processus, jamais sur une recréation. Ensuite,
    // une Live Update qui ne suit pas la visite ouverte (expirée, abandonnée) est retirée.
    LaunchedEffect(container) {
        backStack.resumeOnLaunch(container.launchResume, coldStart) { container.resumableVisit() }
        container.liveUpdates.reconcile()
    }

    // Live Update touchée : le mode courses de sa visite, si elle est encore ouverte. Collecteur toujours composé.
    LaunchedEffect(container) {
        container.shoppingLinks.collect { visitId ->
            // `linkedVisit` ne rend rien pendant une suppression des données.
            container.linkedVisit(visitId)?.let { backStack.openLinkedShopping(it) }
        }
    }

    // Lien d'invitation (#87) : carte de l'invitation pour un compte e-mail, connexion d'abord pour un anonyme.
    LaunchedEffect(container) {
        container.invitationLinkOpenings.collect {
            if (container.accountKind.kind.value == AccountKind.Email) {
                backStack.openInvitation()
            } else {
                container.afterSignIn = AfterSignIn.Invitation
                if (backStack.lastOrNull() != Route.SignIn) backStack.add(Route.SignIn)
            }
        }
    }

    // Liste retirée par un autre membre pendant qu'on la regarde : son écran montre le message, puis se ferme.
    // Liste quittée : ses écrans quittent la pile.
    LaunchedEffect(container) {
        container.sharingNotices.notices.collect { notices ->
            notices.filterIsInstance<AccessChange.Removed>().forEach { removed ->
                backStack.removeAll { it is Route.ShareList && it.listId == removed.listId }
            }
        }
    }

    // Voile et messages de la suppression, par-dessus tous les écrans.
    AccountDeletionOverlay(
        deletion,
        AccountDeletionOverlayActions(
            onAcknowledge = container.accountDeletion::acknowledge,
            onRetry = { container.accountDeletion.start() },
            onCancel = { container.accountDeletion.cancel() },
        ),
        localOnly = container.isLocalOnly,
    )
    AccountSignOutOverlay(
        signOut,
        onAcknowledge = { container.accountSignOut?.acknowledge() },
        onRetry = { container.accountSignOut?.start() },
    )

    val openSignIn = { if (backStack.lastOrNull() != Route.SignIn) backStack.add(Route.SignIn) }
    val openAccount = { if (backStack.lastOrNull() != Route.Account) backStack.add(Route.Account) }

    NavDisplay(
        backStack = backStack,
        onBack = { backStack.removeLastOrNull() },
        entryDecorators =
            listOf(
                rememberSaveableStateHolderNavEntryDecorator(),
                rememberViewModelStoreNavEntryDecorator(),
            ),
        entryProvider =
            entryProvider {
                entry<Route.Lists> {
                    val context = LocalContext.current
                    val model: ListsViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        ListsViewModel(
                                            container.lists,
                                            container.remaps,
                                            sharing = container.sharing,
                                            sharingError = { failure -> sharingErrorText(context, failure) },
                                        )
                                    }
                                },
                        )
                    val invitationsModel: InvitationsViewModel = invitationsViewModel(container)
                    val invitations by invitationsModel.uiState.collectAsState()
                    LaunchedEffect(invitations.openList) {
                        invitations.openList?.let { listId ->
                            invitationsModel.listOpened()
                            backStack.openAcceptedList(listId)
                        }
                    }
                    val notices by container.sharingNotices.notices.collectAsState()
                    val sessionStuck by sessionStuckFlow.collectAsState()
                    val account by container.accountSession.state.collectAsState(AccountState())
                    // Pastille du bouton compte (#108) : prénom relu quand un compte e-mail ne le connaît pas encore
                    // (lancement, connexion, changement de compte). Un échec garde l'icône personne.
                    val missingName = account.kind == AccountKind.Email && account.displayName == null
                    LaunchedEffect(missingName) { if (missingName) container.accountSession.refresh() }
                    val unsentFlow = remember(container) { container.database.outbox().observeCount() }
                    val unsent by unsentFlow.collectAsState(0)
                    ListsRoute(
                        viewModel = model,
                        // Appui sur une liste, ou liste qui vient d'être créée : voir `openListFromLists`.
                        onOpen = { id -> backStack.openListFromLists(id) },
                        onAbout = { if (backStack.lastOrNull() != Route.About) backStack.add(Route.About) },
                        aboutNeedsAttention = sessionStuck,
                        account = listsAccount(container, account, unsent, signOut, openSignIn, openAccount),
                        invitations =
                            ListsInvitationsUi(
                                state = invitations,
                                onAccept = invitationsModel::accept,
                                onDecline = invitationsModel::decline,
                                onOpenAll = {
                                    if (backStack.lastOrNull() !=
                                        Route.Invitations
                                    ) {
                                        backStack.add(Route.Invitations)
                                    }
                                },
                                removed = notices.firstNotNullOfOrNull { it as? AccessChange.Removed },
                                onRemovedShown = container.sharingNotices::acknowledge,
                            ),
                    )
                }
                entry<Route.About> {
                    val reset: SessionResetViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer { SessionResetViewModel(sessionStuckFlow, container::resetSession) }
                                },
                        )
                    val resetState by reset.state.collectAsState()
                    val deletionModel = accountDeletionViewModel(container)
                    val deletionState by deletionModel.state.collectAsState()
                    val kind by container.accountKind.kind.collectAsState()
                    AboutScreen(
                        version = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                        onBack = { if (backStack.lastOrNull() == Route.About) backStack.removeLastOrNull() },
                        sessionReset = resetState,
                        sessionResetActions = reset.actions,
                        accountDeletion = deletionState,
                        accountDeletionActions = deletionModel.actions,
                        // Compte e-mail : « Vos données » est dans l'écran Compte (#108). Sans serveur, pas d'écran
                        // Compte : la suppression reste ici, quel que soit le drapeau `account.kind`.
                        isEmailAccount = container.gateway != null && kind == AccountKind.Email,
                    )
                }
                entry<Route.Account> {
                    val kind by container.accountKind.kind.collectAsState()
                    // Un compte anonyme n'a pas d'écran Compte : déconnexion réussie, données supprimées, ou pile
                    // restaurée après coup. Retour aux listes.
                    LaunchedEffect(kind) { if (kind != AccountKind.Email) backStack.closeAccount() }
                    val deletionModel = accountDeletionViewModel(container)
                    val deletionState by deletionModel.state.collectAsState()
                    val accountModel: AccountViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        AccountViewModel(
                                            session = container.accountSession.takeIf { container.gateway != null },
                                            signOut = container.accountSignOut,
                                            onSignIn = openSignIn,
                                        )
                                    }
                                },
                        )
                    val accountState by accountModel.state.collectAsState()
                    AccountScreen(
                        account = accountState,
                        accountActions = accountModel.actions,
                        onBack = { if (backStack.lastOrNull() == Route.Account) backStack.removeLastOrNull() },
                        accountDeletion = deletionState,
                        accountDeletionActions = deletionModel.actions,
                    )
                }
                entry<Route.SignIn> {
                    val link = remember { container.newAccountLink() }
                    val close = {
                        if (backStack.lastOrNull() == Route.SignIn) backStack.removeLastOrNull()
                        resumeAfterSignIn(container, backStack)
                    }
                    if (link == null) {
                        // Build sans Supabase : rien à quoi se connecter.
                        LaunchedEffect(Unit) { close() }
                    } else {
                        val model: AccountLinkViewModel =
                            viewModel(factory = viewModelFactory { initializer { AccountLinkViewModel(link) } })
                        val linkState by model.state.collectAsState()
                        AccountLinkScreen(state = linkState, actions = model.actions, onClose = { close() })
                    }
                }
                entry<Route.ListDetail>(clazzContentKey = { it.slot }) { key ->
                    val model: ListDetailViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        ListDetailViewModel(
                                            listId = key.listId,
                                            lists = container.lists,
                                            products = container.products,
                                            categories = container.categories,
                                            analyzer = container.analyzer,
                                            remaps = container.remaps,
                                            sharingSources =
                                                ListSharingSources(
                                                    participants = { container.database.participants().observe(it) },
                                                    isOnline = container.isOnline,
                                                    notices = container.sharingNotices.notices,
                                                    acknowledge = container.sharingNotices::acknowledge,
                                                ),
                                            quantityTip = container.quantityTip,
                                        )
                                    }
                                },
                        )
                    ListDetailRoute(
                        viewModel = model,
                        onBack = { backStack.popIfTop(key.slot) },
                        onStartShopping = { listId -> backStack.openStorePicker(listId) },
                        // Partager demande un compte e-mail : un anonyme se connecte d'abord, puis la feuille s'ouvre.
                        onShare =
                            { listId: String ->
                                if (container.accountKind.kind.value == AccountKind.Email) {
                                    backStack.openShareList(listId)
                                } else {
                                    container.afterSignIn = AfterSignIn.Share(listId)
                                    openSignIn()
                                }
                            }.takeIf { container.gateway != null },
                    )
                }
                entry<Route.ShareList>(clazzContentKey = { it.slot }) { key ->
                    val sharing = container.sharing
                    if (sharing == null) {
                        LaunchedEffect(Unit) { backStack.popIfTop(key.slot) }
                    } else {
                        val model: ShareListViewModel =
                            viewModel(
                                factory =
                                    viewModelFactory {
                                        initializer {
                                            val realtime = container.realtime
                                            ShareListViewModel(
                                                listId = key.listId,
                                                service = sharing,
                                                listName = container.lists.observeList(key.listId).map { it?.name },
                                                localRole = container.lists.observeList(key.listId).map { it?.role },
                                                reloads = realtime?.sharingReloads ?: emptyFlow(),
                                                onOpenChanged = { open ->
                                                    if (open) {
                                                        realtime?.sharingSheetOpened(key.listId)
                                                    } else {
                                                        realtime?.sharingSheetClosed(key.listId)
                                                    }
                                                },
                                            )
                                        }
                                    },
                            )
                        ShareListRoute(
                            viewModel = model,
                            onClose = { backStack.popIfTop(key.slot) },
                            onLeft = { backStack.closeList(key.listId) },
                        )
                    }
                }
                entry<Route.Invitations> {
                    val model = invitationsViewModel(container)
                    ReceivedInvitationsRoute(
                        viewModel = model,
                        onOpenList = { backStack.openAcceptedList(it) },
                        onBack = { if (backStack.lastOrNull() == Route.Invitations) backStack.removeLastOrNull() },
                    )
                }
                // Une entrée (et un modèle) par ouverture de lien : un second lien remplace le premier.
                entry<Route.Invitation>(clazzContentKey = { it.slot }) {
                    val model: InvitationLinkViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        InvitationLinkViewModel(
                                            token = container.pendingInvitation,
                                            service = container.sharing,
                                            accountEmail = { container.gateway?.accountEmail() },
                                        )
                                    }
                                },
                        )
                    val close = {
                        container.forgetInvitation()
                        if (backStack.lastOrNull() is Route.Invitation) backStack.removeLastOrNull()
                    }
                    InvitationLinkRoute(
                        viewModel = model,
                        onOpenList = { listId ->
                            container.forgetInvitation()
                            backStack.openAcceptedList(listId)
                        },
                        // « Changer de compte » : la connexion, puis l'invitation reprend avec le jeton gardé.
                        onSwitchAccount = {
                            container.afterSignIn = AfterSignIn.Invitation
                            backStack.removeAll { it is Route.Invitation }
                            openSignIn()
                        },
                        onClose = { close() },
                    )
                }
                entry<Route.StorePicker>(clazzContentKey = { it.slot }) { key ->
                    val model: StorePickerViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        StorePickerViewModel(
                                            container.location,
                                            container.gateway,
                                            container.stores,
                                            container.locationPermission,
                                        )
                                    }
                                },
                        )
                    StorePickerRoute(
                        viewModel = model,
                        // Le mode courses reprend ce choix : voir `storeChoices`.
                        onOutcome = { outcome ->
                            backStack.finishStorePicker(key.slot, outcome)?.let(container::offerStoreChoice)
                        },
                        onBack = { backStack.popIfTop(key.slot) },
                    )
                }
                entry<Route.Shopping>(clazzContentKey = { it.slot }) { key ->
                    val model: ShoppingViewModel =
                        viewModel(
                            factory =
                                viewModelFactory {
                                    initializer {
                                        ShoppingViewModel(
                                            listId = key.listId,
                                            storeId = key.storeId,
                                            deps = container.shopping,
                                            remaps = container.remaps,
                                        )
                                    }
                                },
                        )
                    ShoppingRoute(
                        viewModel = model,
                        onBack = { backStack.popIfTop(key.slot) },
                        onClose = { backStack.popIfTop(key.slot) },
                        onFinished = { summary -> backStack.finishShopping(key.slot, summary) },
                    )
                    // Live Update : seulement avec un magasin (une visite à suivre).
                    if (key.storeId != null) {
                        NotificationPermissionPrompt(
                            container.livePreferences,
                            onGranted = container.liveUpdates::refresh,
                        )
                    }
                }
                entry<Route.ShoppingSummary>(clazzContentKey = { it.slot }) { key ->
                    ShoppingSummaryRoute(summary = key.summary, onClose = { backStack.popIfTop(key.slot) })
                }
            },
    )
}

/**
 * Compte, vu de l'écran Listes : bouton compte toujours visible avec un serveur (#108), « Se connecter » ou pastille.
 * Déconnexion en attente de purge : le bouton reste, désactivé, et seul « Réessayer » est proposé (voile de la
 * déconnexion) ; se reconnecter ouvrirait un compte que la purge effacerait.
 */
@Suppress("LongParameterList") // Les sources de l'écran Listes, sans état propre.
private fun listsAccount(
    container: AppContainer,
    account: AccountState,
    unsent: Int,
    signOut: AccountSignOutState,
    openSignIn: () -> Unit,
    openAccount: () -> Unit,
): ListsAccountUi {
    val free = signOut == AccountSignOutState.Idle
    return ListsAccountUi(
        entry = AccountEntry.of(account.kind, account.displayName).takeIf { container.gateway != null },
        displayName = account.displayName,
        entryEnabled = free,
        needsSignIn = account.needsSignIn && free,
        unsentChanges = unsent,
        onSignIn = openSignIn,
        onAccount = openAccount,
        onContinueWithoutAccount = container::continueWithoutAccount,
    )
}

/** « Vos données » (#68) : dans À propos pour un compte anonyme, dans l'écran Compte pour un compte e-mail. */
@Composable
private fun accountDeletionViewModel(container: AppContainer): AccountDeletionViewModel =
    viewModel(
        factory =
            viewModelFactory {
                initializer {
                    AccountDeletionViewModel(
                        deletion = container.accountDeletion.state,
                        hasOpenVisit = { container.visits.openVisit() != null },
                        start = container.accountDeletion::start,
                        localOnly = container.isLocalOnly,
                    )
                }
            },
    )

/** Invitations reçues : relues à l'ouverture, après une connexion et sur un signal `invitations`. */
@Composable
private fun invitationsViewModel(container: AppContainer): InvitationsViewModel =
    viewModel(
        factory =
            viewModelFactory {
                initializer {
                    InvitationsViewModel(
                        service = container.sharing,
                        isEmailAccount = container.accountKind.kind.map { it == AccountKind.Email },
                        reloads = container.realtime?.invitationReloads ?: emptyFlow(),
                    )
                }
            },
    )

/**
 * Après « Se connecter » : l'action qu'un compte anonyme avait demandée reprend si la connexion a abouti (compte
 * e-mail) ; sinon elle est oubliée.
 */
private fun resumeAfterSignIn(
    container: AppContainer,
    backStack: MutableList<NavKey>,
) {
    val pending = container.afterSignIn ?: return
    container.afterSignIn = null
    if (container.accountKind.kind.value != AccountKind.Email) return
    when (pending) {
        is AfterSignIn.Share -> backStack.openShareList(pending.listId)
        AfterSignIn.Invitation -> if (container.pendingInvitation != null) backStack.openInvitation()
    }
}

/** Texte d'un échec du partage hors de sa feuille (« Quitter la liste » depuis « Mes listes »). */
private fun sharingErrorText(
    context: Context,
    failure: SharingFailure,
): String =
    context.getString(
        when (failure.kind) {
            InviteErrorKind.Offline -> fr.parcourses.feature.lists.R.string.share_offline
            InviteErrorKind.SignInRequired -> fr.parcourses.feature.lists.R.string.err_sign_in
            else -> fr.parcourses.feature.lists.R.string.share_error
        },
    )

/** Sans Supabase, pas de session : rien à réinitialiser. */
private val NotStuck: StateFlow<Boolean> = MutableStateFlow(false)

/** Sans Supabase, pas de compte e-mail : rien à déconnecter. */
private val NoSignOut: StateFlow<AccountSignOutState> = MutableStateFlow(AccountSignOutState.Idle)
