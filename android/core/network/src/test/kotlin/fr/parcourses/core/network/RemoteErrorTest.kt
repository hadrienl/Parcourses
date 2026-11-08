package fr.parcourses.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class RemoteErrorTest {
    @Test
    fun classifiesPostgrestCodes() {
        fun name(code: String) = RemoteError.fromPostgrest(code)::class.simpleName
        assertEquals("Forbidden", name("42501"))
        assertEquals("Constraint", name("23514"))
        assertEquals("Constraint", name("23505"))
        assertEquals("DependencyMissing", name("23503"))
        assertEquals("Rejected", name("23502"))
        assertEquals("Unauthorized", name("PGRST301"))
        assertEquals("Unauthorized", name("PGRST303"))
        assertEquals("Server", name("PGRST001"))
        assertEquals("Rejected", name("PGRST204"))
        assertEquals("Rejected", name("PGRST202"))
        assertEquals("Rejected", name("22023"))
        assertEquals("Server", name("57014"))
        assertEquals("Unexpected", RemoteError.fromPostgrest(null)::class.simpleName)
    }

    @Test
    fun classifiesHttpStatuses() {
        assertTrue(RemoteError.fromHttp(401) is RemoteError.Unauthorized)
        // Un 403 de passerelle n'est jamais un refus RLS.
        assertEquals("403", (RemoteError.fromHttp(403) as RemoteError.Server).code)
        assertEquals("503", (RemoteError.fromHttp(503) as RemoteError.Server).code)
    }

    @Test
    fun retryability() {
        assertFalse(RemoteError.Forbidden().isRetryable)
        assertFalse(RemoteError.Constraint("23505").isRetryable)
        assertFalse(RemoteError.Rejected("22").isRetryable)
        assertTrue(RemoteError.Unexpected().isRetryable)
        assertTrue(RemoteError.Network().isRetryable)
        assertTrue(RemoteError.UnknownCategory("x").isRetryable)
        assertTrue(RemoteError.SecureStorageLocked().isRetryable)
    }

    @Test
    fun onlyClientFailuresWithoutMeaningAreCapped() {
        assertTrue(RemoteError.Server("404").isCappedClientFailure)
        assertFalse(RemoteError.Server("403").isCappedClientFailure)
        assertFalse(RemoteError.Server("429").isCappedClientFailure)
        assertFalse(RemoteError.Server("503").isCappedClientFailure)
        assertFalse(RemoteError.Server("PGRST000").isCappedClientFailure)
        assertFalse(RemoteError.Network().isCappedClientFailure)
    }

    @Test
    fun throwablesAreClassified() {
        val accountChanged = RemoteError.AccountChanged()
        assertEquals(accountChanged, accountChanged.toRemoteError())
        assertTrue(IOException("down").toRemoteError() is RemoteError.Network)
        assertTrue(IllegalStateException().toRemoteError() is RemoteError.Unexpected)
    }

    @Test
    fun cancellationIsNeverClassified() {
        var thrown: Throwable? = null
        try {
            mapped { throw kotlinx.coroutines.CancellationException("stop") }
        } catch (e: Throwable) {
            thrown = e
        }
        assertTrue(thrown is kotlinx.coroutines.CancellationException)
        assertNull((thrown as? RemoteError))
    }
}
