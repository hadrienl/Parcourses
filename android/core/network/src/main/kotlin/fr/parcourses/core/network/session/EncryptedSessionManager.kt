package fr.parcourses.core.network.session

import io.github.jan.supabase.auth.SessionManager
import io.github.jan.supabase.auth.exception.NoSessionFoundException
import io.github.jan.supabase.auth.user.UserSession

/** [SessionManager] de supabase-kt : la session vit dans le stockage chiffré, jamais dans des préférences en clair. */
class EncryptedSessionManager(
    private val store: SecureStateStore,
) : SessionManager {
    override suspend fun saveSession(session: UserSession) {
        store.update { it.copy(session = session) }
    }

    override suspend fun loadSession(): UserSession = store.read().session ?: throw NoSessionFoundException()

    override suspend fun deleteSession() {
        store.update { it.copy(session = null) }
    }
}
