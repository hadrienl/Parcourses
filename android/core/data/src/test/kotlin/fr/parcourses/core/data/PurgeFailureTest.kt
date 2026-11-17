package fr.parcourses.core.data

import android.content.Context
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.data.account.AccountSession
import fr.parcourses.core.data.account.AccountSignOut
import fr.parcourses.core.data.account.AccountSignOutError
import fr.parcourses.core.data.account.AccountSignOutFlag
import fr.parcourses.core.data.account.AccountSignOutOutcome
import fr.parcourses.core.data.account.AccountSwitchReplay
import fr.parcourses.core.data.account.InMemoryAccountKindFlag
import fr.parcourses.core.data.account.InMemoryAccountSignOutFlag
import fr.parcourses.core.data.account.InMemoryAccountSwitchFlag
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.account.ObservedAccountSwitchFlag
import fr.parcourses.core.data.account.PurgeFailure
import fr.parcourses.core.data.account.PurgeOperation
import fr.parcourses.core.data.account.PurgeStep
import fr.parcourses.core.data.account.PurgeStepException
import fr.parcourses.core.data.account.failedPurgeStep
import fr.parcourses.core.data.account.purgeStep
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.database.CategorySeed
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.StoredSessionAccount
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.uuid.Uuid

/**
 * Purges en échec (#129) : compteur `purgeFailureCount` (déconnexion et rejeu d'un changement de compte), seuil au 3ᵉ
 * échec, remise à 0, code public `purge-<opération>-<étape>` et adresse `mailto:` sans donnée personnelle.
 */
@RunWith(AndroidJUnit4::class)
class PurgeFailureTest : DataTest() {
    private val gateway = fakeGateway()
    private val kind = InMemoryAccountKindFlag()
    private val cursors = InMemorySyncCursors()
    private val session = AccountSession(null, kind)
    private val switch = ObservedAccountSwitchFlag(InMemoryAccountSwitchFlag()) { session.switchFlagCleared() }

    /** Référentiel des catégories illisible tant que vrai : la purge échoue à l'étape `categories`. */
    private var seedFails = false
    private var clearFails = false

    private val purge by lazy {
        LocalDataPurge(
            db,
            cursors,
            seed = { if (seedFails) error("disque plein") else CategorySeed.bundled() },
            accountKind = kind,
            switchFlag = switch,
        )
    }

    private val host =
        object : AccountDeletionHost {
            override suspend fun suspendSync() = Unit

            override suspend fun endShopping() = Unit

            override suspend fun clearLocalState() {
                if (clearFails) error("préférences illisibles")
            }

            override fun resumeSync() = Unit

            override suspend fun rebuild() = Unit
        }

    private fun signOut(flag: AccountSignOutFlag = InMemoryAccountSignOutFlag()) =
        AccountSignOut(
            gateway,
            purge,
            host,
            flag,
            isOnline = { online },
            flush = {},
            unsent = { 0 },
            failures = session,
        )

    private val replay by lazy {
        AccountSwitchReplay(gateway, switch, cursors, kind, Mutex(), failures = session) { purge.run() }
    }

    private suspend fun blockedPurge() = session.blockedPurge.first()

    private suspend fun blockedSwitch() = session.blockedSwitch.first()

    @Test
    fun theCounterRisesAtEachFailedSignOutAndTheThresholdIsTheThirdFailure() =
        runBlocking {
            kind.write(AccountKind.Email)
            seedFails = true
            val signOut = signOut()
            assertEquals(0, session.purgeFailureCount.value)
            assertEquals(3, AccountSession.PURGE_FAILURE_THRESHOLD)
            assertEquals(3, session.purgeFailureThreshold)

            // Confirmation, puis deux « Réessayer » : rien ne change avant le seuil.
            assertEquals(AccountSignOutOutcome.Failed(AccountSignOutError.Unknown), signOut.run())
            assertEquals(1, session.purgeFailureCount.value)
            assertNull(blockedPurge())
            assertEquals(AccountSignOutOutcome.Failed(AccountSignOutError.Unknown), signOut.run())
            assertEquals(2, session.purgeFailureCount.value)
            assertNull(blockedPurge())
            // Reprise au lancement : même purge, même compteur.
            assertEquals(AccountSignOutOutcome.Failed(AccountSignOutError.Unknown), signOut.resumePending())
            assertEquals(3, session.purgeFailureCount.value)

            val expected = PurgeFailure(PurgeOperation.SignOut, PurgeStep.Categories)
            assertEquals(expected, session.lastPurgeFailure.value)
            assertEquals(expected, blockedPurge())
            assertEquals("purge-signout-categories", session.lastPurgeFailure.value?.publicCode)
            // Pas de changement de compte en attente : pas de bandeau.
            assertNull(blockedSwitch())

            // « Réessayer » réussi : le compteur revient à 0, l'alerte retrouve son texte.
            seedFails = false
            assertEquals(AccountSignOutOutcome.SignedOut, signOut.run())
            assertEquals(0, session.purgeFailureCount.value)
            assertNull(session.lastPurgeFailure.value)
            assertNull(blockedPurge())
        }

    @Test
    fun theCounterRisesAtEachFailedReplayAndASuccessClearsTheBanner() =
        runBlocking {
            kind.write(AccountKind.Email)
            repository().createList("Courses de A", now)
            cursors.accountId = Uuid.random()
            gateway.email = "tom@exemple.fr"
            switch.write()
            seedFails = true

            // Lancement, puis deux retours au premier plan.
            repeat(2) { attempt ->
                assertFalse(replay.run())
                assertEquals(attempt + 1, session.purgeFailureCount.value)
                assertNull(blockedSwitch())
            }
            assertFalse(replay.run())
            assertEquals(3, session.purgeFailureCount.value)
            val expected = PurgeFailure(PurgeOperation.Switch, PurgeStep.Categories)
            assertEquals(expected, blockedSwitch())
            assertEquals("purge-switch-categories", session.lastPurgeFailure.value?.publicCode)
            assertTrue(switch.isPending)

            // « Réessayer » du bandeau : le rejeu aboutit, le compteur revient à 0, le bandeau disparaît.
            seedFails = false
            assertTrue(replay.run())
            assertFalse(switch.isPending)
            assertEquals(0, session.purgeFailureCount.value)
            assertNull(blockedSwitch())
            assertEquals(gateway.account, cursors.accountId)
        }

    /** `account.switch` effacé par un autre chemin (purge d'une déconnexion) : le compteur des rejeux revient à 0. */
    @Test
    fun aSwitchFlagClearedByAnotherPathResetsTheCounter() =
        runBlocking {
            cursors.accountId = Uuid.random()
            gateway.email = "tom@exemple.fr"
            switch.write()
            seedFails = true
            repeat(3) { assertFalse(replay.run()) }
            assertEquals(3, session.purgeFailureCount.value)

            // La déconnexion échoue après sa purge (préférences) : sa purge a effacé `account.switch`, puis l'échec de
            // la déconnexion compte seul.
            seedFails = false
            clearFails = true
            val signOut = signOut()
            assertEquals(AccountSignOutOutcome.Failed(AccountSignOutError.Unknown), signOut.run())
            assertFalse(switch.isPending)
            assertEquals(1, session.purgeFailureCount.value)
            assertEquals(PurgeFailure(PurgeOperation.SignOut, PurgeStep.Preferences), session.lastPurgeFailure.value)
            assertNull(blockedSwitch())

            // Chaque essai efface de nouveau le drapeau (déjà absent) : la déconnexion continue de compter.
            signOut.run()
            signOut.run()
            assertEquals(3, session.purgeFailureCount.value)
            assertEquals(PurgeFailure(PurgeOperation.SignOut, PurgeStep.Preferences), blockedPurge())
        }

    /** La première étape en échec compte : chaque étape a son code. */
    @Test
    fun eachStepHasItsPublicCode() =
        runBlocking {
            assertEquals(
                listOf(
                    "purge-signout-store",
                    "purge-signout-categories",
                    "purge-signout-session",
                    "purge-signout-preferences",
                    "purge-signout-unknown",
                    "purge-switch-store",
                    "purge-switch-categories",
                    "purge-switch-session",
                    "purge-switch-preferences",
                    "purge-switch-unknown",
                ),
                PurgeOperation.entries.flatMap { op -> PurgeStep.entries.map { PurgeFailure(op, it).publicCode } },
            )

            // Session : `signOut()` refusé par le stockage de la session.
            gateway.failNext("signOut", IllegalStateException("Keystore"))
            signOut().run()
            assertEquals(PurgeStep.Session, session.lastPurgeFailure.value?.step)

            // Préférences : le drapeau de la déconnexion n'a pas pu être écrit.
            val unwritable =
                object : AccountSignOutFlag {
                    override val isPending = false

                    override fun write() = error("stockage plein")

                    override fun clear() = Unit
                }
            signOut(unwritable).run()
            assertEquals(PurgeFailure(PurgeOperation.SignOut, PurgeStep.Preferences), session.lastPurgeFailure.value)

            // Session : la session stockée est illisible pendant un rejeu.
            switch.write()
            val unreadable =
                AccountSwitchReplay(
                    object : RemoteGateway by gateway {
                        override suspend fun storedSessionAccount(): StoredSessionAccount? =
                            throw RemoteError.Unauthorized()
                    },
                    switch,
                    cursors,
                    kind,
                    Mutex(),
                    failures = session,
                ) { purge.run() }
            assertFalse(unreadable.run())
            assertEquals(PurgeFailure(PurgeOperation.Switch, PurgeStep.Session), session.lastPurgeFailure.value)
        }

    /** Base locale illisible : la purge échoue à l'étape `store`, avant les catégories. */
    @Test
    fun aClosedStoreFailsAtTheStoreStep() =
        runBlocking {
            val closed =
                ParcoursesDatabaseFactory.createInMemory(
                    ApplicationProvider.getApplicationContext<Context>(),
                    Dispatchers.IO,
                    AndroidSQLiteDriver(),
                )
            closed.close()
            try {
                LocalDataPurge(closed, cursors).run()
                fail("La purge d'une base fermée doit échouer")
            } catch (e: PurgeStepException) {
                assertEquals(PurgeStep.Store, e.step)
                // Le message ne porte que le code de l'étape, jamais le texte de l'erreur système.
                assertEquals("purge step: store", e.message)
            }
        }

    @Test
    fun aStepKeepsTheFirstFailedStepAndLetsCancellationThrough() {
        val inner =
            runCatching {
                purgeStep(PurgeStep.Preferences) { purgeStep(PurgeStep.Store) { error("disque plein") } }
            }.exceptionOrNull()
        assertEquals(PurgeStep.Store, inner?.failedPurgeStep)
        assertEquals(PurgeStep.Unknown, IllegalStateException().failedPurgeStep)

        val cancellation = CancellationException("fermé")
        val thrown = runCatching { purgeStep(PurgeStep.Store) { throw cancellation } }.exceptionOrNull()
        assertSame(cancellation, thrown)
    }

    /** Objet seul, encodé RFC 3986 (parenthèses comprises), sans corps ni donnée personnelle. */
    @Test
    fun theMailtoIsExactAndCarriesNoPersonalData() {
        val failure = PurgeFailure(PurgeOperation.SignOut, PurgeStep.Store)
        assertEquals(
            "mailto:parcourses@hadrien.eu?subject=Parcourses%20%3A%20purge%20impossible%20%28purge-signout-store%29",
            failure.supportMailto,
        )
        assertEquals("Parcourses : purge impossible (purge-signout-store)", failure.supportSubject)
        assertEquals(
            "mailto:parcourses@hadrien.eu?subject=Parcourses%20%3A%20purge%20impossible%20%28purge-switch-unknown%29",
            PurgeFailure(PurgeOperation.Switch, PurgeStep.Unknown).supportMailto,
        )
        // Seul l'objet : ni corps, ni autre paramètre, ni autre adresse.
        for (operation in PurgeOperation.entries) {
            for (step in PurgeStep.entries) {
                val mailto = PurgeFailure(operation, step).supportMailto
                assertEquals(1, mailto.count { it == '@' })
                assertEquals(1, mailto.count { it == '?' })
                assertFalse(mailto.contains("body"))
                assertFalse(mailto.contains('&'))
                assertTrue(mailto.substringAfter("subject=").all { it.isLetterOrDigit() || it in "-._~%" })
            }
        }
    }

    private fun repository() = RoomListRepository(db)
}
