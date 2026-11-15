package fr.parcourses.core.data.sharing

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.network.RealtimeEvent
import fr.parcourses.core.network.RealtimeSignalSource
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.uuid.Uuid

/** `RealtimeSignals` (#87 §6.2, §6.6) : regroupement, premier plan seulement, descente à la (re)jonction. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
class RealtimeSignalsTest {
    private val me = Uuid.random()
    private var account = me
    private var echoes = emptySet<String>()
    private val list = Uuid.random()
    private val kind = MutableStateFlow(AccountKind.Email)
    private var pulls = 0

    /** Canal simulé : compte ses ouvertures et ses fermetures. */
    private class FakeSource : RealtimeSignalSource {
        val events = MutableSharedFlow<RealtimeEvent>(extraBufferCapacity = 16)
        var opened = 0
        var open = 0
        val users = mutableListOf<Uuid>()

        override fun signals(userId: Uuid): Flow<RealtimeEvent> =
            flow {
                opened += 1
                open += 1
                users += userId
                try {
                    emitAll(events)
                } finally {
                    open -= 1
                }
            }
    }

    private val source = FakeSource()

    private fun TestScope.signals(): RealtimeSignals =
        RealtimeSignals(
            source = source,
            accountId = { account },
            accountKind = kind,
            requestPull = { pulls += 1 },
            scope = backgroundScope,
            isEcho = { it in echoes },
        )

    private fun changed(
        kind: String,
        listId: Uuid? = list,
    ) = RealtimeEvent.Changed(listId, kind)

    @Test
    fun signalsWithin300msMakeASinglePull() =
        runTest {
            val signals = signals()
            signals.foreground()
            runCurrent()
            assertEquals(1, source.open)
            assertEquals(listOf(me), source.users)

            source.events.emit(RealtimeEvent.Subscribed)
            advanceTimeBy(100)
            source.events.emit(changed("items"))
            advanceTimeBy(100)
            source.events.emit(changed("list"))
            advanceTimeBy(150)
            runCurrent()
            // Jonction et deux signaux dans la même fenêtre : une seule descente.
            assertEquals(1, pulls)
            assertTrue(signals.isConnected.value)

            source.events.emit(changed("items"))
            advanceTimeBy(299)
            runCurrent()
            assertEquals(1, pulls)
            advanceTimeBy(2)
            runCurrent()
            assertEquals(2, pulls)
        }

    @Test
    fun aReconnectionPullsAgain() =
        runTest {
            val signals = signals()
            signals.foreground()
            runCurrent()
            source.events.emit(RealtimeEvent.Subscribed)
            advanceTimeBy(1_000)
            // Le canal retombe puis se rejoint : les messages manqués ne sont pas rejoués.
            source.events.emit(RealtimeEvent.Subscribed)
            advanceTimeBy(1_000)
            runCurrent()
            assertEquals(2, pulls)
        }

    @Test
    fun theChannelClosesInTheBackgroundAndReopensInTheForeground() =
        runTest {
            val signals = signals()
            runCurrent()
            assertEquals(0, source.opened)

            signals.foreground()
            runCurrent()
            assertEquals(1, source.open)
            source.events.emit(RealtimeEvent.Subscribed)
            runCurrent()

            signals.background()
            runCurrent()
            assertEquals(0, source.open)
            assertFalse(signals.isConnected.value)
            // Un signal émis pendant l'arrière-plan n'atteint personne.
            source.events.emit(changed("items"))
            advanceTimeBy(1_000)
            assertEquals(0, pulls)

            signals.foreground()
            runCurrent()
            assertEquals(2, source.opened)
            source.events.emit(RealtimeEvent.Subscribed)
            advanceTimeBy(400)
            assertEquals(1, pulls)
        }

    @Test
    fun anAnonymousAccountOpensNoChannel() =
        runTest {
            kind.value = AccountKind.Anonymous
            val signals = signals()
            signals.foreground()
            runCurrent()
            assertEquals(0, source.opened)

            // Adresse liée : le canal s'ouvre sans attendre un nouveau premier plan.
            kind.value = AccountKind.Email
            runCurrent()
            assertEquals(1, source.open)
            kind.value = AccountKind.Anonymous
            runCurrent()
            assertEquals(0, source.open)
        }

    @Test
    fun invitationsReloadTheInvitationsWithoutPulling() =
        runTest {
            val signals = signals()
            var reloads = 0
            backgroundScope.launch { signals.invitationReloads.collect { reloads += 1 } }
            signals.foreground()
            runCurrent()

            source.events.emit(changed("invitations", listId = null))
            advanceTimeBy(400)
            assertEquals(1, reloads)
            assertEquals(0, pulls)
        }

    @Test
    fun membersReloadTheOpenSharingSheet() =
        runTest {
            val signals = signals()
            val reloaded = mutableListOf<Set<String>>()
            backgroundScope.launch { signals.sharingReloads.collect { reloaded += it } }
            signals.foreground()
            runCurrent()

            // Feuille fermée : une descente seulement.
            source.events.emit(changed("members"))
            advanceTimeBy(400)
            assertEquals(1, pulls)
            assertTrue(reloaded.isEmpty())

            signals.sharingSheetOpened(list.toString())
            source.events.emit(changed("members"))
            advanceTimeBy(400)
            assertEquals(2, pulls)
            assertEquals(listOf(setOf(list.toString())), reloaded)

            signals.sharingSheetClosed(list.toString())
            source.events.emit(changed("members"))
            advanceTimeBy(400)
            assertEquals(1, reloaded.size)
        }

    @Test
    fun aNewSessionReopensTheChannelForTheNewAccount() =
        runTest {
            val signals = signals()
            signals.foreground()
            runCurrent()
            val other = Uuid.random()
            account = other
            signals.sessionChanged()
            runCurrent()
            assertEquals(2, source.opened)
            assertEquals(1, source.open)
            // Le canal rouvert est celui du nouveau compte, l'ancien est fermé.
            assertEquals(listOf(me, other), source.users)
        }

    @Test
    fun theEchoOfMyOwnItemWritesAsksForNoPull() =
        runTest {
            val signals = signals()
            signals.foreground()
            runCurrent()
            echoes = setOf(list.toString())

            source.events.emit(changed("items"))
            advanceTimeBy(400)
            assertEquals(0, pulls)

            // Un autre type de signal, ou une autre liste, passe.
            source.events.emit(changed("members"))
            advanceTimeBy(400)
            assertEquals(1, pulls)
            source.events.emit(changed("items", Uuid.random()))
            advanceTimeBy(400)
            assertEquals(2, pulls)
        }
}
