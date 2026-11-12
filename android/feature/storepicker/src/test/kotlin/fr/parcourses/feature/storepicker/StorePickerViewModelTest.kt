package fr.parcourses.feature.storepicker

import fr.parcourses.core.location.LocationAuthorization
import fr.parcourses.core.location.LocationResult
import fr.parcourses.core.network.RemoteError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import kotlin.time.Instant

@OptIn(ExperimentalCoroutinesApi::class)
class StorePickerViewModelTest {
    private val location = FakeLocationProvider()
    private val gateway = FakeGateway()
    private val cache = FakeStoreRepository()
    private val clock = Instant.fromEpochSeconds(1_800_000_000)

    @Before
    fun setUp() = Dispatchers.setMain(StandardTestDispatcher())

    @After
    fun tearDown() = Dispatchers.resetMain()

    private val memory = InMemoryLocationPermissionMemory()

    private fun model(
        remote: FakeGateway? = gateway,
        requestTimeoutMs: Long = 10_000,
    ) = StorePickerViewModel(location, remote, cache, memory, requestTimeoutMs = requestTimeoutMs, now = { clock })

    private fun TestScope.started(vm: StorePickerViewModel = model()): StorePickerViewModel {
        vm.ensureStarted()
        advanceUntilIdle()
        return vm
    }

    private val StorePickerViewModel.phase get() = uiState.value.phase

    /** Tous les résultats émis : on lit jusqu'à ce que plus rien n'arrive (temps virtuel). */
    private suspend fun StorePickerViewModel.drainOutcomes(): List<StorePickerOutcome> {
        val all = mutableListOf<StorePickerOutcome>()
        while (true) all += withTimeoutOrNull(1_000) { outcomes.first() } ?: break
        return all
    }

    // --- Position précise ---

    @Test
    fun aClearlyClosestStoreIsProposedAndTheRestListed() =
        runTest {
            gateway.nearby =
                { _, _, _, _ -> listOf(nearbyRow("Loin", 800.0), nearbyRow("Ici", 40.0), nearbyRow("Pas loin", 300.0)) }
            val vm = started()
            val phase = vm.phase as StorePickerPhase.Precise
            assertEquals("Ici", phase.proposed?.name)
            assertEquals(setOf("Pas loin", "Loin"), phase.others.map { it.name }.toSet())
            assertEquals(40.0, phase.proposed?.distanceM)
            // Rayon précis, point lu une fois, transmis tel quel.
            assertEquals(listOf(Triple(48.85, 2.35, 3_000)), gateway.nearbyCalls)
            assertEquals(1, location.reads)
        }

    @Test
    fun twoStoresTooCloseToTellApartAreNotGuessed() =
        runTest {
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0), nearbyRow("B", 70.0)) }
            val phase = started().phase as StorePickerPhase.Precise
            assertNull(phase.proposed)
            assertEquals(2, phase.others.size)
        }

    @Test
    fun theGapMustExceedThePointInaccuracy() =
        runTest {
            location.result = { LocationResult.Fix(FakeLocationProvider.fix(accuracy = 90.0)) }
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0), nearbyRow("B", 110.0)) }
            assertNull((started().phase as StorePickerPhase.Precise).proposed)
        }

    @Test
    fun aStoreBeyondTheProposalDistanceIsOnlyListed() =
        runTest {
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("Loin", 400.0)) }
            val phase = started().phase as StorePickerPhase.Precise
            assertNull(phase.proposed)
            assertEquals(listOf("Loin"), phase.others.map { it.name })
        }

    @Test
    fun aPointTooRoughNeverProposesAStore() =
        runTest {
            location.result = { LocationResult.Fix(FakeLocationProvider.fix(accuracy = 400.0)) }
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("Ici", 10.0)) }
            assertNull((started().phase as StorePickerPhase.Precise).proposed)
        }

    @Test
    fun aStalePointNeverProposesAStore() =
        runTest {
            location.result = { LocationResult.Fix(FakeLocationProvider.fix().copy(isStale = true)) }
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("Ici", 10.0)) }
            assertNull((started().phase as StorePickerPhase.Precise).proposed)
        }

    // --- Position approximative ---

    @Test
    fun anApproximatePositionKeepsNoDistanceAndGuessesNothing() =
        runTest {
            location.authorization = LocationAuthorization.Approximate
            gateway.nearby =
                { _, _, _, _ -> listOf(nearbyRow("Zèbre", 5.0), nearbyRow("Épicerie", 9.0), nearbyRow("Abc", 1.0)) }
            val phase = started().phase as StorePickerPhase.Approximate
            assertEquals(listOf("Abc", "Épicerie", "Zèbre"), phase.candidates.map { it.name })
            assertTrue(phase.candidates.all { it.distanceM == null })
            assertEquals(10_000, gateway.nearbyCalls.single().third)
        }

    @Test
    fun grantingPrecisionLaterReloadsWithThePreciseRadius() =
        runTest {
            location.authorization = LocationAuthorization.Approximate
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0)) }
            val vm = started()
            location.authorization = LocationAuthorization.Precise
            vm.onPermissionResult(canAskAgain = true)
            advanceUntilIdle()
            assertTrue(vm.phase is StorePickerPhase.Precise)
            assertEquals(listOf(10_000, 3_000), gateway.nearbyCalls.map { it.third })
        }

    @Test
    fun decliningPrecisionIsSaidAndKeepsTheList() =
        runTest {
            location.authorization = LocationAuthorization.Approximate
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0)) }
            val vm = started()
            vm.onPermissionResult(canAskAgain = true)
            advanceUntilIdle()
            assertTrue(vm.uiState.value.precisionDeclined)
            assertTrue(vm.phase is StorePickerPhase.Approximate)
            assertEquals(1, gateway.nearbyCalls.size)
        }

    // --- Autorisation ---

    @Test
    fun beforeAnyRequestTheScreenExplainsAndReadsNothing() =
        runTest {
            location.authorization = LocationAuthorization.Denied
            val vm = started()
            assertEquals(StorePickerPhase.PermissionNeeded, vm.phase)
            assertTrue(vm.uiState.value.offersSearch)
            assertEquals(0, location.reads)
            assertTrue(gateway.nearbyCalls.isEmpty())
        }

    @Test
    fun aSimpleRefusalCanBeAskedAgain() =
        runTest {
            location.authorization = LocationAuthorization.Denied
            val vm = started()
            vm.onPermissionResult(canAskAgain = true)
            assertEquals(StorePickerPhase.Denied(canAskAgain = true), vm.phase)
        }

    @Test
    fun doNotAskAgainLeadsToTheSettings() =
        runTest {
            location.authorization = LocationAuthorization.Denied
            val vm = started()
            vm.onPermissionResult(canAskAgain = false)
            assertEquals(StorePickerPhase.Denied(canAskAgain = false), vm.phase)
            assertTrue(vm.uiState.value.offersSearch)
        }

    @Test
    fun grantingTheRequestStartsTheSearch() =
        runTest {
            location.authorization = LocationAuthorization.Denied
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0)) }
            val vm = started()
            location.authorization = LocationAuthorization.Precise
            vm.onPermissionResult(canAskAgain = true)
            advanceUntilIdle()
            assertTrue(vm.phase is StorePickerPhase.Precise)
            assertEquals(1, location.reads)
        }

    @Test
    fun comingBackFromTheSettingsWithAccessReloads() =
        runTest {
            location.authorization = LocationAuthorization.Denied
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0)) }
            val vm = started()
            vm.onPermissionResult(canAskAgain = false)
            vm.refreshAfterForeground()
            advanceUntilIdle()
            // Rien n'a changé : pas de relance.
            assertEquals(StorePickerPhase.Denied(canAskAgain = false), vm.phase)
            location.authorization = LocationAuthorization.Precise
            vm.refreshAfterForeground()
            advanceUntilIdle()
            assertTrue(vm.phase is StorePickerPhase.Precise)
        }

    @Test
    fun comingBackWhileAStoreListIsShownDoesNotReload() =
        runTest {
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0)) }
            val vm = started()
            vm.refreshAfterForeground()
            advanceUntilIdle()
            assertEquals(1, location.reads)
        }

    @Test
    fun theAuthorizationRevokedDuringTheReadShowsTheRefusal() =
        runTest {
            location.result = {
                location.authorization = LocationAuthorization.Denied
                LocationResult.Denied
            }
            val vm = started()
            assertEquals(StorePickerPhase.Denied(canAskAgain = true), vm.phase)
            assertTrue(gateway.nearbyCalls.isEmpty())
        }

    @Test
    fun aPermanentRefusalIsRememberedForTheNextVisit() =
        runTest {
            // #54 : sans mémoire, le premier appui sur « Utiliser ma position » de la fois suivante ne faisait rien.
            location.authorization = LocationAuthorization.Denied
            // Deuxième refus : la demande était encore proposable juste avant.
            started().onPermissionResult(canAskAgain = false, couldAskBefore = true)
            assertTrue(memory.deniedPermanently)

            val next = started(model())
            assertEquals(StorePickerPhase.Denied(canAskAgain = false), next.phase)
            assertEquals(0, location.reads)
        }

    @Test
    fun aDismissedDialogIsNotRememberedAsAPermanentRefusal() =
        runTest {
            // Android 11+ : dialogue fermé (appui à côté) à la première demande, le rationale reste faux.
            location.authorization = LocationAuthorization.Denied
            val vm = started()
            vm.onPermissionResult(canAskAgain = false, couldAskBefore = false)
            assertFalse(memory.deniedPermanently)
            assertEquals(StorePickerPhase.PermissionNeeded, started(model()).phase)
        }

    @Test
    fun aSimpleRefusalIsNotRemembered() =
        runTest {
            location.authorization = LocationAuthorization.Denied
            started().onPermissionResult(canAskAgain = true)
            assertFalse(memory.deniedPermanently)
            assertEquals(StorePickerPhase.PermissionNeeded, started(model()).phase)
        }

    @Test
    fun accessGivenBackInTheSettingsForgetsThePermanentRefusal() =
        runTest {
            memory.deniedPermanently = true
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0)) }
            val vm = started()
            assertTrue(vm.phase is StorePickerPhase.Precise)
            assertFalse(memory.deniedPermanently)
            // Puis retiré de nouveau (sans « Ne plus demander ») : l'écran explique avant de demander.
            location.authorization = LocationAuthorization.Denied
            assertEquals(StorePickerPhase.PermissionNeeded, started(model()).phase)
        }

    @Test
    fun aGrantAfterAPermanentRefusalForgetsIt() =
        runTest {
            memory.deniedPermanently = true
            location.authorization = LocationAuthorization.Denied
            val vm = started()
            location.authorization = LocationAuthorization.Precise
            vm.onPermissionResult(canAskAgain = false, couldAskBefore = true)
            assertFalse(memory.deniedPermanently)
        }

    // --- Autres états ---

    @Test
    fun noPointMeansLocationUnavailableWithSearchOffered() =
        runTest {
            location.result = { LocationResult.Unavailable }
            val vm = started()
            assertEquals(StorePickerPhase.LocationUnavailable, vm.phase)
            assertTrue(vm.uiState.value.offersSearch)
        }

    @Test
    fun noStoreInTheRadiusOffersSearch() =
        runTest {
            val vm = started()
            assertEquals(StorePickerPhase.NoStore, vm.phase)
            assertTrue(vm.uiState.value.offersSearch)
        }

    @Test
    fun aNetworkFailureMeansOfflineAndKeepsTheRecents() =
        runTest {
            cache.upsertStore("r1", "Récent", null, null, null)
            cache.markUsed("r1", clock)
            gateway.nearby = { _, _, _, _ -> throw RemoteError.Network() }
            val vm = started()
            assertEquals(StorePickerPhase.Offline, vm.phase)
            assertEquals(
                listOf("Récent"),
                vm.uiState.value.recents
                    .map { it.name },
            )
            assertTrue(vm.uiState.value.offersSearch)
        }

    @Test
    fun aSlowServerCountsAsOffline() =
        runTest {
            gateway.nearby = { _, _, _, _ ->
                delay(60_000)
                emptyList()
            }
            assertEquals(StorePickerPhase.Offline, started(model(requestTimeoutMs = 10_000)).phase)
        }

    @Test
    fun comingBackFromTheLocationSettingsReadsThePositionAgain() =
        runTest {
            location.result = { LocationResult.Unavailable }
            val vm = started()
            assertEquals(StorePickerPhase.LocationUnavailable, vm.phase)
            // Retour au premier plan sans être passé par les réglages : rien n'est relu.
            vm.refreshAfterForeground()
            advanceUntilIdle()
            assertEquals(1, location.reads)

            // #54 : la localisation activée dans les réglages, le retour relance la recherche.
            vm.locationSettingsOpened()
            location.result = { LocationResult.Fix(FakeLocationProvider.fix()) }
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0)) }
            vm.refreshAfterForeground()
            advanceUntilIdle()
            assertTrue(vm.phase is StorePickerPhase.Precise)
            assertEquals(2, location.reads)
            // Une seule fois.
            vm.refreshAfterForeground()
            advanceUntilIdle()
            assertEquals(2, location.reads)
        }

    @Test
    fun aSessionNotYetCreatedCountsAsOffline() =
        runTest {
            // #54 : premier lancement hors ligne, la session anonyme n'existe pas encore.
            gateway.nearby = { _, _, _, _ -> throw RemoteError.Unauthorized() }
            val vm = started()
            assertEquals(StorePickerPhase.Offline, vm.phase)
            gateway.search = { _, _ -> throw RemoteError.Unauthorized() }
            vm.onQueryChange("carrefour")
            advanceUntilIdle()
            assertEquals(StoreSearchState.Offline, vm.uiState.value.search)
        }

    @Test
    fun aServerErrorIsNotBlamedOnTheNetwork() =
        runTest {
            gateway.nearby = { _, _, _, _ -> throw RemoteError.Server("503") }
            assertEquals(StorePickerPhase.ServiceError, started().phase)
        }

    @Test
    fun withoutSupabaseConfigurationTheAppStaysLocal() =
        runTest {
            val vm = started(model(remote = null))
            assertEquals(StorePickerPhase.Offline, vm.phase)
            assertEquals(0, location.reads)
        }

    @Test
    fun retryingCancelsTheLoadInProgress() =
        runTest {
            val firstGate = CompletableDeferred<Unit>()
            var call = 0
            var completed = 0
            gateway.nearby = { _, _, _, _ ->
                val index = ++call
                if (index == 1) firstGate.await()
                completed++
                listOf(nearbyRow(if (index == 1) "Premier" else "Second", 40.0))
            }
            val vm = model()
            vm.start()
            advanceUntilIdle()
            vm.start()
            advanceUntilIdle()
            // Même débloquée, la première requête a été annulée : elle ne finit pas et n'écrase rien.
            firstGate.complete(Unit)
            advanceUntilIdle()
            assertEquals("Second", ((vm.phase) as StorePickerPhase.Precise).proposed?.name)
            assertEquals(1, completed)
            assertEquals(2, location.reads)
        }

    @Test
    fun aDoubleTapReturnsTheStoreOnce() =
        runTest {
            val vm = model()
            val store = StoreCandidate("a", "A")
            vm.select(store)
            vm.select(store)
            advanceUntilIdle()
            assertEquals(listOf<StorePickerOutcome>(StorePickerOutcome.Store("a")), vm.drainOutcomes())
            assertEquals(1, cache.upserts)
        }

    @Test
    fun tappingWithoutStoreWhileSavingDoesNotReturnTwice() =
        runTest {
            val vm = model()
            vm.select(StoreCandidate("a", "A"))
            vm.continueWithoutStore()
            advanceUntilIdle()
            assertEquals(listOf<StorePickerOutcome>(StorePickerOutcome.Store("a")), vm.drainOutcomes())
        }

    @Test
    fun aDoubleTapOnWithoutStoreReturnsOnce() =
        runTest {
            val vm = model()
            vm.continueWithoutStore()
            vm.continueWithoutStore()
            vm.select(StoreCandidate("a", "A"))
            advanceUntilIdle()
            assertEquals(listOf<StorePickerOutcome>(StorePickerOutcome.WithoutStore), vm.drainOutcomes())
            assertTrue(cache.cache.isEmpty())
        }

    @Test
    fun searchIsOfferedOnceThePositionIsHandled() =
        runTest {
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0)) }
            val vm = model()
            vm.start()
            assertFalse(vm.uiState.value.offersSearch)
            advanceUntilIdle()
            assertTrue(vm.phase is StorePickerPhase.Precise)
            assertTrue(vm.uiState.value.offersSearch)
            gateway.nearby = { _, _, _, _ -> throw RemoteError.Server("503") }
            vm.start()
            advanceUntilIdle()
            assertEquals(StorePickerPhase.ServiceError, vm.phase)
            assertTrue(vm.uiState.value.offersSearch)
        }

    @Test
    fun theKeyboardSearchKeyDoesNotWaitForTheDebounce() =
        runTest {
            gateway.search = { _, _ -> listOf(searchRow("X")) }
            val vm = started(model())
            vm.onQueryChange("carre")
            vm.submitSearch()
            runCurrent()
            assertTrue(vm.uiState.value.search is StoreSearchState.Results)
        }

    @Test
    fun leavingTheScreenSendsNothingMore() =
        runTest {
            val gate = CompletableDeferred<Unit>()
            location.result = {
                gate.await()
                LocationResult.Fix(FakeLocationProvider.fix())
            }
            val vm = model()
            vm.start()
            advanceUntilIdle()
            vm.cancel()
            gate.complete(Unit)
            advanceUntilIdle()
            assertTrue(gateway.nearbyCalls.isEmpty())
        }

    @Test
    fun startingTwiceFromTheScreenReadsOnce() =
        runTest {
            gateway.nearby = { _, _, _, _ -> listOf(nearbyRow("A", 40.0)) }
            val vm = model()
            vm.ensureStarted()
            vm.ensureStarted()
            advanceUntilIdle()
            assertEquals(1, location.reads)
        }

    // --- Choix et cache ---

    @Test
    fun choosingAStoreCachesItWithoutDistanceAndReturnsIt() =
        runTest {
            val row = nearbyRow("Ici", 40.0, organic = true)
            gateway.nearby = { _, _, _, _ -> listOf(row) }
            val vm = started()
            val proposed = (vm.phase as StorePickerPhase.Precise).proposed!!
            vm.select(proposed)
            advanceUntilIdle()
            assertEquals(StorePickerOutcome.Store(row.id.toString()), vm.outcomes.first())
            val saved = cache.cache.getValue(row.id.toString())
            assertEquals("Ici", saved.name)
            assertEquals(clock, saved.lastUsedAt)
            assertTrue(saved.organicAisle)
        }

    @Test
    fun onlyTheChosenStoreEntersTheCache() =
        runTest {
            gateway.nearby =
                { _, _, _, _ -> listOf(nearbyRow("A", 40.0), nearbyRow("B", 500.0), nearbyRow("C", 900.0)) }
            val vm = started()
            vm.select((vm.phase as StorePickerPhase.Precise).proposed!!)
            advanceUntilIdle()
            assertEquals(listOf("A"), cache.cache.values.map { it.name })
        }

    @Test
    fun aRecentStoreKeepsItsCachedOrganicAisle() =
        runTest {
            cache.upsertStore("r1", "Récent", null, null, organicAisle = true)
            cache.markUsed("r1", clock)
            val vm = started()
            vm.select(
                vm.uiState.value.recents
                    .single(),
            )
            advanceUntilIdle()
            assertTrue(cache.cache.getValue("r1").organicAisle)
            assertEquals(StorePickerOutcome.Store("r1"), vm.outcomes.first())
        }

    @Test
    fun theMostRecentlyChosenStoreComesFirst() =
        runTest {
            val first = model()
            first.select(StoreCandidate("a", "A"))
            advanceUntilIdle()
            val second =
                StorePickerViewModel(location, gateway, cache, now = { clock + kotlin.time.Duration.parse("1h") })
            second.select(StoreCandidate("b", "B"))
            advanceUntilIdle()
            val vm = started(model())
            assertEquals(
                listOf("B", "A"),
                vm.uiState.value.recents
                    .map { it.name },
            )
        }

    @Test
    fun aCacheFailureIsSaidAndNothingIsReturned() =
        runTest {
            cache.failWrites = true
            val vm = model()
            vm.select(StoreCandidate("a", "A"))
            advanceUntilIdle()
            assertTrue(vm.uiState.value.selectionFailed)
            vm.dismissSelectionFailure()
            assertFalse(vm.uiState.value.selectionFailed)
            // On peut réessayer une fois le disque libéré.
            cache.failWrites = false
            vm.select(StoreCandidate("a", "A"))
            advanceUntilIdle()
            assertEquals(StorePickerOutcome.Store("a"), vm.outcomes.first())
        }

    @Test
    fun continuingWithoutAStoreWritesNothing() =
        runTest {
            val vm = started()
            vm.continueWithoutStore()
            assertEquals(StorePickerOutcome.WithoutStore, vm.outcomes.first())
            assertTrue(cache.cache.isEmpty())
        }

    // --- Recherche ---

    @Test
    fun aShortQueryDoesNotSearch() =
        runTest {
            val vm = started(model())
            vm.onQueryChange("c")
            advanceUntilIdle()
            assertEquals(StoreSearchState.Idle, vm.uiState.value.search)
            assertTrue(gateway.searchCalls.isEmpty())
        }

    @Test
    fun searchWaitsForTheTypingToPauseThenAsksForTwentyResults() =
        runTest {
            gateway.search = { _, _ -> listOf(searchRow("Carrefour Market")) }
            val vm = started(model())
            vm.onQueryChange("ca")
            advanceTimeBy(100)
            vm.onQueryChange("car")
            vm.onQueryChange("  carre  ")
            assertEquals(StoreSearchState.Searching, vm.uiState.value.search)
            advanceUntilIdle()
            assertEquals(listOf("carre" to 20), gateway.searchCalls)
            val results = vm.uiState.value.search as StoreSearchState.Results
            assertEquals(listOf("Carrefour Market"), results.stores.map { it.name })
            assertNull(results.stores.single().distanceM)
        }

    @Test
    fun emptyingTheQueryClearsTheResults() =
        runTest {
            gateway.search = { _, _ -> listOf(searchRow("X")) }
            val vm = started(model())
            vm.onQueryChange("carre")
            advanceUntilIdle()
            vm.onQueryChange("")
            assertEquals(StoreSearchState.Idle, vm.uiState.value.search)
        }

    @Test
    fun aSlowOutdatedSearchNeverOverwritesTheLatest() =
        runTest {
            gateway.search = { q, _ ->
                if (q == "lent") delay(5_000)
                listOf(searchRow(q))
            }
            val vm = started(model())
            vm.onQueryChange("lent")
            advanceTimeBy(400)
            vm.onQueryChange("rapide")
            advanceUntilIdle()
            assertEquals(listOf("rapide"), (vm.uiState.value.search as StoreSearchState.Results).stores.map { it.name })
        }

    @Test
    fun searchFailuresAreClassified() =
        runTest {
            val vm = started(model())
            gateway.search = { _, _ -> throw RemoteError.Network() }
            vm.onQueryChange("offline")
            advanceUntilIdle()
            assertEquals(StoreSearchState.Offline, vm.uiState.value.search)
            gateway.search = { _, _ -> throw RemoteError.Server("500") }
            vm.onQueryChange("erreur")
            advanceUntilIdle()
            assertEquals(StoreSearchState.Failed, vm.uiState.value.search)
        }

    @Test
    fun searchWithoutGatewayIsOffline() =
        runTest {
            val vm = started(model(remote = null))
            vm.onQueryChange("carre")
            assertEquals(StoreSearchState.Offline, vm.uiState.value.search)
        }

    @Test
    fun choosingASearchResultCachesIt() =
        runTest {
            val row = searchRow("Trouvé")
            gateway.search = { _, _ -> listOf(row) }
            val vm = started(model())
            vm.onQueryChange("trouve")
            advanceUntilIdle()
            vm.select((vm.uiState.value.search as StoreSearchState.Results).stores.single())
            advanceUntilIdle()
            assertEquals(StorePickerOutcome.Store(row.id.toString()), vm.outcomes.first())
            assertEquals("Trouvé", cache.cache.getValue(row.id.toString()).name)
        }
}
