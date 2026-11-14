package fr.parcourses.core.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.data.account.AccountLink
import fr.parcourses.core.data.account.AccountLinkError
import fr.parcourses.core.data.account.AccountLinkHost
import fr.parcourses.core.data.account.AccountLinkPhase
import fr.parcourses.core.data.account.AccountSignOut
import fr.parcourses.core.data.account.AccountSignOutError
import fr.parcourses.core.data.account.AccountSignOutOutcome
import fr.parcourses.core.data.account.DeletionGuardedGateway
import fr.parcourses.core.data.account.InMemoryAccountDeletionFlag
import fr.parcourses.core.data.account.InMemoryAccountKindFlag
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.AccountRekey
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.entity.ProductEntity
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.dto.EmailCodePurpose
import fr.parcourses.core.network.dto.EmailCodeStatus
import fr.parcourses.core.network.dto.ListRow
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
    private val engine by lazy { SyncEngine(guarded, db, cursors, classify, dependencies) }
    private val repository by lazy { RoomListRepository(db) }
    private var sessionChanges = 0

    private val host =
        object : AccountLinkHost {
            override suspend fun adoptAccount(expected: Uuid): Int? = engine.adoptSessionAccount(expected)

            override fun sessionDidChange() {
                sessionChanges++
            }
        }

    private fun link() = AccountLink(guarded, kind, host, isOnline = { online }, now = { now })

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
            assertFalse(done.welcomeBack)
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
            gateway.linkStatus = EmailCodeStatus(422, "email_exists")
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
            assertTrue(done.welcomeBack)
            assertEquals(1, done.listsAdded)
            assertEquals("Léa B", done.displayName)
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

            gateway.linkStatus = EmailCodeStatus(429, "over_email_send_rate_limit")
            link.requestCode("lea@exemple.fr")
            assertEquals(AccountLinkError.RateLimited, link.state.value.error)
            assertEquals(AccountLinkPhase.EnterEmail, link.state.value.phase)

            online = false
            link.requestCode("lea@exemple.fr")
            assertEquals(AccountLinkError.Offline, link.state.value.error)

            online = true
            gateway.linkStatus = EmailCodeStatus.Sent
            link.requestCode("lea@exemple.fr")
            gateway.failNext("verifyCode", RemoteError.Unauthorized(authCode = "otp_expired"))
            link.verify("000000")
            assertEquals(AccountLinkError.InvalidCode, link.state.value.error)
            // 15 minutes plus tard, le même refus veut dire « expiré ».
            advance(16.minutes)
            gateway.failNext("verifyCode", RemoteError.Unauthorized(authCode = "otp_expired"))
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
    fun signingOutNeedsTheNetworkAndAnEmptyQueueThenPurgesTheDevice() =
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
            var flushed = 1
            val signOut =
                AccountSignOut(
                    guarded,
                    LocalDataPurge(db, cursors, accountKind = kind),
                    host,
                    isOnline = { online },
                    flush = { flushed },
                )

            online = false
            assertEquals(AccountSignOutOutcome.Failed(AccountSignOutError.Offline), signOut.run())
            online = true
            assertEquals(AccountSignOutOutcome.Failed(AccountSignOutError.Unsynced), signOut.run())
            assertTrue(steps.isEmpty())
            assertEquals(
                list.id,
                db
                    .lists()
                    .getAll()
                    .single()
                    .id,
            )

            flushed = 0
            val before = gateway.account
            assertEquals(AccountSignOutOutcome.SignedOut, signOut.run())

            assertEquals(listOf("suspend", "shopping", "clear", "rebuild"), steps)
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
}
