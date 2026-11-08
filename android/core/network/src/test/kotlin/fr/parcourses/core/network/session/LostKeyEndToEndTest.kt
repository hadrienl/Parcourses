package fr.parcourses.core.network.session

import fr.parcourses.core.network.FakeSupabase
import fr.parcourses.core.network.GatewayHarness
import fr.parcourses.core.network.RemoteError
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** Vrai DataStore + passerelle, clé simulée perdue : le changement de compte est signalé, pas adopté. */
class LostKeyEndToEndTest {
    @get:Rule
    val folder = TemporaryFolder()

    private fun launch(
        env: KeysetEnvironment,
        server: FakeSupabase,
        scope: CoroutineScope,
    ): GatewayHarness {
        val store =
            DataStoreSecureStateStore.create(
                File(folder.root, "datastore/session.pb"),
                File(folder.root, "datastore/account.json"),
                KeystoreAeadSource(env),
                scope,
            )
        return GatewayHarness(server, store)
    }

    @Test
    fun aLostKeyYieldsAnAccountChangeInsteadOfASilentSwitch() =
        runBlocking<Unit> {
            val env = FakeKeysetEnvironment()
            val firstScope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
            val first = launch(env, FakeSupabase(), firstScope)
            val original = first.gateway.ensureSession()
            first.close()
            firstScope.cancel()

            // Clé maîtresse perdue entre deux lancements ; le serveur donnera un autre compte anonyme.
            env.aliasPresent = false
            val secondScope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
            val second =
                launch(env, FakeSupabase().apply { userId = "bbbbbbbb-0000-4000-8000-000000000002" }, secondScope)
            try {
                val error = runCatching { second.gateway.ensureSession() }.exceptionOrNull()
                assertTrue("attendu AccountChanged, reçu $error", error is RemoteError.AccountChanged)
                assertEquals(1, env.masterKeyDeletions)
                // Le compte d'origine reste connu pour réidentifier les données locales.
                assertEquals(original.toString(), second.store.read().lastAccountId)
            } finally {
                second.close()
                secondScope.cancel()
            }
        }
}
