package fr.parcourses.app

import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED

/**
 * Passerelle sans session locale (C3) : le serveur est hors d'atteinte, seul l'appareil est purgé. Les erreurs
 * passent par la continuation : levées par le proxy, ces exceptions vérifiées seraient enveloppées.
 */
internal fun gatewayWithoutSession(): RemoteGateway =
    java.lang.reflect.Proxy.newProxyInstance(
        RemoteGateway::class.java.classLoader,
        arrayOf(RemoteGateway::class.java),
    ) { _, method, args ->
        val failure: Throwable =
            when (method.name) {
                "sessionAccountId" -> RemoteError.Unauthorized(noLocalSession = true)
                "ensureSession" -> RemoteError.Network(notSent = true)
                "signOutLocally" -> return@newProxyInstance Unit
                else -> throw UnsupportedOperationException(method.name)
            }
        @Suppress("UNCHECKED_CAST")
        (args.last() as Continuation<Any?>).resumeWith(Result.failure(failure))
        COROUTINE_SUSPENDED
    } as RemoteGateway

/** Hôte de la suppression qui n'a rien à arrêter : ni synchro, ni courses, ni Live Update. */
internal class IdleAccountDeletionHost : AccountDeletionHost {
    override suspend fun suspendSync() = Unit

    override suspend fun endShopping() = Unit

    override suspend fun clearLocalState() = Unit

    override fun resumeSync() = Unit

    override suspend fun rebuild() = Unit
}
