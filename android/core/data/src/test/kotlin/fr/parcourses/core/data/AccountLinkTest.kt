package fr.parcourses.core.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.data.account.AccountLink
import fr.parcourses.core.data.account.AccountLinkError
import fr.parcourses.core.data.account.AccountLinkHost
import fr.parcourses.core.data.account.AccountLinkOutcome
import fr.parcourses.core.data.account.AccountLinkPhase
import fr.parcourses.core.data.account.AccountSignOut
import fr.parcourses.core.data.account.AccountSignOutError
import fr.parcourses.core.data.account.AccountSignOutOutcome
import fr.parcourses.core.data.account.DeletionGuardedGateway
import fr.parcourses.core.data.account.InMemoryAccountDeletionFlag
import fr.parcourses.core.data.account.InMemoryAccountKindFlag
import fr.parcourses.core.data.account.InMemoryAccountSignOutFlag
import fr.parcourses.core.data.account.InMemoryAccountSwitchFlag
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.AccountRekey
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.SyncDependencies
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.entity.ProductEntity
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.AuthRequestError
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.dto.EmailCodePurpose
import fr.parcourses.core.network.dto.ListRow
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.uuid.Uuid

/** Comptes e-mail (#87, lot 87.5) : liaison, connexion à un compte existant, reprise, déconnexion, session perdue. */
@RunWith(AndroidJUnit4::class)
class AccountLinkTest : DataTest() {
    private val gateway = fakeGateway()
    private val kind = InMemoryAccountKindFlag()
    private val cursors = InMemorySyncCursors()
    private val guarded by lazy { DeletionGuardedGateway(gateway, InMemoryAccountDeletionFlag(), kind) }
    private val accountDependencies =
        SyncDependencies(now = { now }, jitter = { 1.0 }, isOnline = { online }, accountKind = { kind.kind.value })
    private val engine by lazy { SyncEngine(guarded, db, cursors, classify, accountDependencies) }
    private val repository by lazy { RoomListRepository(db) }
    private var sessionChanges = 0
    private val syncSteps = mutableListOf<String>()

    private val host =
        object : AccountLinkHost {
            override suspend fun adoptAccount(expected: Uuid): Int? = engine.adoptSessionAccount(expected)

            override fun sessionDidChange() {
                sessionChanges++
            }

            override suspend fun suspendSync() {
                syncSteps += "suspend"
                engine.suspend()
            }

            override fun resumeSync() {
                syncSteps += "resume"
                engine.resume()
            }

            override suspend fun dataAccount(): Uuid? = cursors.accountId

            override suspend fun pendingChanges(): Int = db.outbox().pendingCount()

            override suspend fun adoptDataAccount(account: Uuid) {
                syncSteps += "adopt"
                cursors.adopt(account, AccountKind.Email)
            }

            override suspend fun purgeLocalData() {
                syncSteps += "purge"
                if (purgeFailures-- > 0) error("base verrouillée")
                LocalDataPurge(db, cursors, accountKind = kind).run()
            }
        }

    private val switch = InMemoryAccountSwitchFlag()
    private var purgeFailures = 0

    private fun link() = AccountLink(guarded, kind, host, isOnline = { online }, switchFlag = switch, now = { now })

    @Test
    fun aNewAddressIsLinkedToTheSameAccountWithItsName() =
        runBlocking {
            engine.drain()
            val anonymous = gateway.account
            val link = link()
            assertTrue(link.state.value.asksDisplayName)

            link.requestCode(" Lea@Exemple.fr ", "  Léa ")
            assertEquals(AccountLinkPhase.EnterCode, link.state.value.phase)
            assertEquals(EmailCodePurpose.Link, link.state.value.purpose)
            assertEquals("lea@exemple.fr", link.state.value.email)
            assertEquals(listOf("linkEmail:lea@exemple.fr"), gateway.callsOf("linkEmail"))

            link.verify("123 456")

            val done = link.state.value
            assertEquals(AccountLinkPhase.Done, done.phase)
            assertEquals(AccountLinkOutcome.Linked, done.outcome)
            assertEquals(anonymous, gateway.account)
            assertEquals(AccountKind.Email, kind.kind.value)
            assertEquals("Léa", gateway.displayName)
            assertEquals(1, sessionChanges)
            assertTrue(gateway.deletedTokens.isEmpty())
        }

    @Test
    fun aTakenAddressSignsInAndAddsThePhoneListsToTheAccount() =
        runBlocking {
            val mine = repository.createList("Apéro", now)
            repository.addItem(mine.id, "chips", "chips", null, null, "savory-grocery", now)
            // Liste « Courses » du premier lancement, jamais touchée : elle n'est pas ajoutée au compte.
            repository.createList("Courses", now)
            engine.drain()
            val anonymous = gateway.account
            gateway.linkRefusal = AuthRequestError(422, "email_exists")
            val existing = Uuid.random()
            gateway.codeAccount = existing
            gateway.displayName = null
            val link = link()

            link.requestCode("lea@exemple.fr", "Léa")
            assertEquals(EmailCodePurpose.SignIn, link.state.value.purpose)
            assertEquals(1, gateway.callsOf("signInWithEmail").size)
            // Le compte existant a déjà un prénom : il est gardé.
            gateway.displayName = "Léa B"
            link.verify("654321")

            val done = link.state.value
            assertEquals(AccountLinkPhase.Done, done.phase)
            assertEquals(AccountLinkOutcome.SignedIn("Léa B", addedLists = 1), done.outcome)
            assertEquals(existing, cursors.accountId)
            assertEquals(listOf("Apéro"), db.lists().getAll().map { it.name })
            assertNotEquals(
                mine.id,
                db
                    .lists()
                    .getAll()
                    .single()
                    .id,
            )
            // L'ancien compte anonyme est supprimé avec le jeton gardé avant le code.
            assertEquals(listOf("token-$anonymous"), gateway.deletedTokens)
            assertTrue(gateway.callsOf("setDisplayName").isEmpty())
        }

    @Test
    fun anEmailAccountWithoutSessionSignsInWithoutAnAnonymousAccount() =
        runBlocking {
            kind.write(AccountKind.Email)
            gateway.hasSession = false
            engine.drain(pull = true)
            // Passe forcée suivante : elle tente de retrouver une session, sans jamais en créer.
            engine.drain(pull = true)
            // Vecteur 009 : pas de compte anonyme, la synchro attend la reconnexion.
            assertTrue(engine.waitsForSession.value)
            assertTrue(gateway.callsOf("ensureSession").isEmpty())
            val link = link()
            assertFalse(link.state.value.asksDisplayName)

            link.requestCode("lea@exemple.fr")
            assertTrue(gateway.callsOf("linkEmail").isEmpty())
            assertEquals(EmailCodePurpose.SignIn, link.state.value.purpose)
            link.verify("111111")

            assertEquals(AccountLinkPhase.Done, link.state.value.phase)
            assertTrue(gateway.deletedTokens.isEmpty())
            assertFalse(engine.waitsForSession.value)
        }

    @Test
    fun errorsAreToldAndNothingChanges() =
        runBlocking {
            val link = link()
            link.requestCode("pas-une-adresse")
            assertEquals(AccountLinkError.InvalidEmail, link.state.value.error)
            assertTrue(gateway.callsOf("linkEmail").isEmpty())

            gateway.linkRefusal = AuthRequestError(429, "over_email_send_rate_limit")
            link.requestCode("lea@exemple.fr")
            assertEquals(AccountLinkError.RateLimited, link.state.value.error)
            assertEquals(AccountLinkPhase.EnterEmail, link.state.value.phase)

            online = false
            link.requestCode("lea@exemple.fr")
            assertEquals(AccountLinkError.Offline, link.state.value.error)

            online = true
            gateway.linkRefusal = null
            link.requestCode("lea@exemple.fr")
            gateway.failNext("verifyCode", AuthRequestError(403, "otp_expired"))
            link.verify("000000")
            assertEquals(AccountLinkError.InvalidCode, link.state.value.error)
            // 15 minutes plus tard, le même refus veut dire « expiré ».
            advance(16.minutes)
            gateway.failNext("verifyCode", AuthRequestError(403, "otp_expired"))
            link.verify("000000")
            assertEquals(AccountLinkError.ExpiredCode, link.state.value.error)
            link.verify("12")
            assertEquals(AccountLinkError.InvalidCode, link.state.value.error)
            assertEquals(AccountKind.Anonymous, kind.kind.value)

            link.changeEmail()
            assertEquals(AccountLinkPhase.EnterEmail, link.state.value.phase)
            assertEquals("lea@exemple.fr", link.state.value.email)
        }

    @Test
    fun displayNamesAreCheckedLikeTheServer() {
        assertEquals("Léa", AccountLink.cleanedDisplayName("  Léa "))
        assertEquals("Jean-Marc O'Neil", AccountLink.cleanedDisplayName("Jean-Marc O'Neil"))
        assertNull(AccountLink.cleanedDisplayName(" "))
        assertNull(AccountLink.cleanedDisplayName("x".repeat(41)))
        assertNull(AccountLink.cleanedDisplayName("lea@exemple.fr"))
        assertNull(AccountLink.cleanedDisplayName("www.exemple.fr"))
        assertNull(AccountLink.cleanedDisplayName("Lé​a"))
        assertNull(AccountLink.normalizedEmail("lea@exemple"))
        assertEquals("lea+courses@exemple.fr", AccountLink.normalizedEmail("Lea+Courses@Exemple.FR"))
    }

    @Test
    fun theRekeyDropsListsOfOthersAndUntouchedEmptyListsAndUnknownProducts() =
        runBlocking {
            val previous = Uuid.random().toString()
            val other = Uuid.random().toString()
            val shared = insertList(state = SyncState.SYNCED)
            db.lists().upsert(shared.copy(ownerId = other))
            insertItem(shared.id)
            val empty = insertList(state = SyncState.SYNCED)
            db.lists().upsert(empty.copy(ownerId = previous))
            val renamed = insertList(state = SyncState.SYNCED)
            db.lists().upsert(renamed.copy(ownerId = previous, updatedAt = now + 1.hours))
            val mine = insertList(state = SyncState.SYNCED)
            val known = Uuid.random().toString()
            db.products().upsertAll(listOf(ProductEntity(known, "Lait", "lait", "dairy")))
            insertItem(mine.id, label = "lait", productId = known)
            insertItem(mine.id, label = "purgé", productId = Uuid.random().toString(), position = 1)

            val result = AccountRekey(db).run(now, previousAccountId = previous)

            assertEquals(2, result.resentLists)
            val lists = db.lists().getAll()
            assertEquals(setOf(result.remap[renamed.id], result.remap[mine.id]), lists.map { it.id }.toSet())
            assertTrue(lists.all { it.ownerId == null && it.syncState == SyncState.PENDING })
            val items = db.items().getAll().associateBy { it.label }
            assertEquals(setOf("lait", "purgé"), items.keys)
            assertEquals(known, items.getValue("lait").productId)
            assertNull(items.getValue("purgé").productId)
            assertTrue(items.values.none { it.isOnServer })
        }

    @Test
    fun signingOutWarnsAboutUnsentChangesNeedsTheNetworkThenPurgesTheDevice() =
        runBlocking {
            kind.write(AccountKind.Email)
            val list = repository.createList("Courses", now)
            val steps = mutableListOf<String>()
            val host =
                object : AccountDeletionHost {
                    override suspend fun suspendSync() {
                        steps += "suspend"
                    }

                    override suspend fun endShopping() {
                        steps += "shopping"
                    }

                    override suspend fun clearLocalState() {
                        steps += "clear"
                    }

                    override fun resumeSync() {
                        steps += "resume"
                    }

                    override suspend fun rebuild() {
                        steps += "rebuild"
                    }
                }
            val flag = InMemoryAccountSignOutFlag()
            // Un changement de compte en attente n'a plus d'objet après la purge de déconnexion.
            switch.write()
            val signOut =
                AccountSignOut(
                    guarded,
                    LocalDataPurge(db, cursors, accountKind = kind, switchFlag = switch),
                    host,
                    flag,
                    isOnline = { online },
                    flush = {},
                    unsent = { db.outbox().all().size },
                )

            // Avertissement, pas de refus : la liste jamais envoyée est comptée après l'arrêt de la synchro.
            assertEquals(1, signOut.prepare())
            assertEquals(listOf("suspend"), steps)
            signOut.abandon()
            assertEquals(listOf("suspend", "resume"), steps)
            steps.clear()
            online = false
            assertEquals(AccountSignOutOutcome.Failed(AccountSignOutError.Offline), signOut.run())
            assertEquals(listOf("resume"), steps)
            assertEquals(
                list.id,
                db
                    .lists()
                    .getAll()
                    .single()
                    .id,
            )
            steps.clear()

            online = true
            val before = gateway.account
            assertEquals(AccountSignOutOutcome.SignedOut, signOut.run())

            assertEquals(listOf("suspend", "shopping", "suspend", "clear", "rebuild"), steps)
            assertFalse(switch.isPending)
            assertFalse(flag.isPending)
            assertEquals(1, gateway.callsOf("signOut").size)
            assertTrue(db.lists().getAll().isEmpty())
            assertEquals(AccountKind.Anonymous, kind.kind.value)
            // Nouveau compte anonyme vide.
            assertNotEquals(before, gateway.account)
            assertNull(cursors.accountId)
        }

    @Test
    fun aListPulledFromAnotherOwnerIsNotResentByTheEngine() =
        runBlocking {
            val owner = Uuid.random()
            val listId = Uuid.random()
            gateway.remoteLists = listOf(ListRow(listId, owner, "De Léa", now, now))
            engine.drain(pull = true)
            assertEquals(owner.toString(), db.lists().get(listId.toString())?.ownerId)

            // Session perdue d'un compte anonyme : nouveau compte, reprise.
            gateway.hasSession = false
            gateway.remoteLists = emptyList()
            engine.drain(pull = true)
            engine.drain(pull = true)

            assertTrue(db.lists().getAll().isEmpty())
            assertTrue(gateway.callsOf("saveList").isEmpty())
        }

    /** Règle 4 : la synchronisation est suspendue pendant la vérification du code, puis reprise. */
    @Test
    fun theSyncIsSuspendedWhileTheCodeIsVerified() =
        runBlocking {
            engine.drain()
            var suspendedDuringVerify = false
            gateway.beforeCall = { if (it == "verifyCode") suspendedDuringVerify = syncSteps.lastOrNull() == "suspend" }
            val link = link()
            link.requestCode("lea@exemple.fr")
            link.verify("123456")
            assertTrue(suspendedDuringVerify)
            assertEquals(listOf("suspend", "resume"), syncSteps)

            // Code refusé : reprise aussi.
            val other = link()
            other.requestCode("tom@exemple.fr")
            gateway.failNext("verifyCode", AuthRequestError(403, "otp_expired"))
            other.verify("000000")
            assertEquals(listOf("suspend", "resume", "suspend", "resume"), syncSteps)
        }

    /**
     * Règle 2 : un compte e-mail A qui se connecte à un autre compte B ne lui renvoie aucune liste. L'appareil est
     * purgé, B est adopté sans reprise, et l'écran prévient d'abord des modifications non envoyées.
     */
    @Test
    fun anEmailAccountSigningInToAnotherAccountSendsItNothing() =
        runBlocking {
            kind.write(AccountKind.Email)
            val list = repository.createList("Courses de A", now - 1.minutes)
            repository.renameList(list.id, "Courses de A", now)
            engine.drain()
            val accountA = gateway.account
            repository.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            gateway.hasSession = false
            val saved = gateway.callsOf("saveList").size
            val accountB = Uuid.random()
            gateway.codeAccount = accountB
            val link = link()
            link.prepare()
            assertEquals(1, link.state.value.unsentChanges)

            link.requestCode("tom@exemple.fr")
            link.verify("123456")

            assertEquals(AccountLinkOutcome.SignedIn(null, addedLists = 0), link.state.value.outcome)
            assertTrue(db.lists().getAll().isEmpty())
            assertEquals(AccountKind.Email, kind.kind.value)
            assertEquals(listOf(accountB), gateway.acknowledged.takeLast(1))
            // Compte des données écrit tout de suite après la purge, avant toute passe (suites de la relecture, 3).
            assertEquals(listOf("suspend", "purge", "adopt", "resume"), syncSteps)
            engine.drain(pull = true)
            assertEquals(saved, gateway.callsOf("saveList").size)
            assertEquals(accountB, cursors.accountId)
            assertNotEquals(accountA, accountB)
            assertTrue(gateway.deletedTokens.isEmpty())
        }

    /** Règle 3 : drapeau posé avant `signOut`, purge rejouée tant qu'il existe, « Réessayer » sans redémarrage. */
    @Test
    fun anInterruptedSignOutIsReplayedUntilThePurgeEnds() =
        runBlocking {
            kind.write(AccountKind.Email)
            repository.createList("Courses", now)
            var failures = 1
            var flagAtSignOut = false
            val flag = InMemoryAccountSignOutFlag()
            gateway.beforeCall = { if (it == "signOut") flagAtSignOut = flag.isPending }
            val failingHost =
                object : AccountDeletionHost {
                    override suspend fun suspendSync() = Unit

                    override suspend fun endShopping() = Unit

                    override suspend fun clearLocalState() {
                        if (failures-- > 0) error("préférences illisibles")
                    }

                    override fun resumeSync() = Unit

                    override suspend fun rebuild() = Unit
                }
            val signOut =
                AccountSignOut(
                    guarded,
                    LocalDataPurge(db, cursors, accountKind = kind),
                    failingHost,
                    flag,
                    isOnline = { online },
                    flush = {},
                    unsent = { 0 },
                )

            assertEquals(AccountSignOutOutcome.Failed(AccountSignOutError.Unknown), signOut.run())
            assertTrue(flagAtSignOut)
            assertTrue(flag.isPending)

            // Relance : la purge reprend, sans demander ni réseau ni file vide.
            online = false
            assertEquals(AccountSignOutOutcome.SignedOut, signOut.resumePending())
            assertFalse(flag.isPending)
            assertNull(signOut.resumePending())
        }

    /** Majeur 2 : une annulation pendant la vérification (écran fermé) laisse le déroulé finir et la synchro reprise. */
    @Test
    fun aCancellationDuringTheVerificationLeavesTheSyncResumed() =
        runBlocking {
            engine.drain()
            val link = link()
            link.requestCode("lea@exemple.fr")
            lateinit var job: Job
            gateway.beforeCall = { if (it == "verifyCode") job.cancel() }
            job = launch { link.verify("123456") }
            job.join()

            assertTrue(job.isCancelled)
            assertEquals(AccountLinkPhase.Done, link.state.value.phase)
            assertEquals(listOf("suspend", "resume"), syncSteps)
            gateway.beforeCall = {}
            repository.createList("Après", now)
            engine.drain()
            assertTrue(gateway.callsOf("saveList").isNotEmpty())
        }

    /**
     * Majeur 1 : processus arrêté pendant un passage de A à B. Un nouveau moteur avec les curseurs de A (compte e-mail)
     * et la session de B ne renvoie aucune liste de A vers B : les données de A quittent l'appareil.
     */
    @Test
    fun aNewEngineWithTheCursorsOfAnEmailAccountAndTheSessionOfAnotherSendsItNothing() =
        runBlocking {
            kind.write(AccountKind.Email)
            val list = repository.createList("Courses de A", now - 1.minutes)
            repository.renameList(list.id, "Courses de A", now)
            repository.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            engine.drain()
            assertEquals(AccountKind.Email, cursors.accountKind)
            val saved = gateway.callsOf("saveList").size
            // Relance après l'arrêt : la session est déjà celle de B, la purge n'a pas eu lieu.
            gateway.account = Uuid.random()
            val relaunched = SyncEngine(guarded, db, cursors, classify, accountDependencies)

            relaunched.drain(pull = true)

            assertEquals(saved, gateway.callsOf("saveList").size)
            assertTrue(gateway.callsOf("insertItem").size <= 1)
            assertTrue(db.lists().getAll().isEmpty())
            assertTrue(db.items().getAll().isEmpty())
            assertTrue(db.outbox().all().isEmpty())
            assertEquals(gateway.account, cursors.accountId)
        }

    /** Majeur 1 et mineur 10 : purge en échec, on sort du rapprochement avec « Réessayer », synchro arrêtée. */
    @Test
    fun aFailedPurgeOffersToRetryAndKeepsTheSyncStopped() =
        runBlocking {
            kind.write(AccountKind.Email)
            repository.createList("Courses de A", now)
            engine.drain()
            gateway.hasSession = false
            gateway.codeAccount = Uuid.random()
            purgeFailures = 1
            val link = link()
            link.requestCode("tom@exemple.fr")

            link.verify("123456")

            assertEquals(AccountLinkPhase.Merging, link.state.value.phase)
            assertEquals(AccountLinkError.Unknown, link.state.value.error)
            assertFalse(link.state.value.busy)
            assertTrue(switch.isPending)
            assertEquals(listOf("suspend", "purge"), syncSteps)

            link.retryMerge()

            assertEquals(AccountLinkPhase.Done, link.state.value.phase)
            assertFalse(switch.isPending)
            assertEquals(listOf("suspend", "purge", "purge", "adopt", "resume"), syncSteps)
            assertTrue(db.lists().getAll().isEmpty())
        }

    /** Un essai de code qui échoue n'efface `account.switch` que s'il l'a posé lui-même. */
    @Test
    fun aFailedCodeKeepsASwitchFlagItDidNotSet() =
        runBlocking {
            kind.write(AccountKind.Email)
            gateway.hasSession = false
            val link = link()
            link.requestCode("tom@exemple.fr")
            gateway.failNext("verifyCode", AuthRequestError(403, "otp_expired"), times = 2)

            link.verify("000000")
            assertFalse(switch.isPending)

            switch.write()
            link.verify("000000")
            assertTrue(switch.isPending)
        }

    /** Déconnexion en attente de purge : aucun compte ne naît avant elle. */
    @Test
    fun noAccountIsCreatedWhileASignOutAwaitsItsPurge() =
        runBlocking {
            val signOutFlag = InMemoryAccountSignOutFlag().also { it.write() }
            val blocked = DeletionGuardedGateway(gateway, InMemoryAccountDeletionFlag(), kind, signOutFlag)
            gateway.hasSession = false
            assertTrue(runCatching { blocked.ensureSession() }.exceptionOrNull() is RemoteError.Unauthorized)
            assertTrue(gateway.callsOf("ensureSession").isEmpty())
        }

    /** Relecture de #95 (3) : la reprise au premier plan a déjà purgé et adopté B ; « Réessayer » ne purge pas encore. */
    @Test
    fun retryingAfterTheForegroundReplayDoesNotPurgeTwice() =
        runBlocking {
            kind.write(AccountKind.Email)
            repository.createList("Courses de A", now)
            engine.drain()
            gateway.hasSession = false
            val accountB = Uuid.random()
            gateway.codeAccount = accountB
            purgeFailures = 1
            val link = link()
            link.requestCode("tom@exemple.fr")
            link.verify("123456")
            assertEquals(AccountLinkError.Unknown, link.state.value.error)
            // Reprise au premier plan : purge faite, B adopté, drapeau effacé.
            LocalDataPurge(db, cursors, accountKind = kind).run()
            cursors.adopt(accountB, AccountKind.Email)
            switch.clear()
            syncSteps.clear()

            link.retryMerge()

            assertEquals(AccountLinkPhase.Done, link.state.value.phase)
            assertEquals(listOf("resume"), syncSteps)
        }
}
