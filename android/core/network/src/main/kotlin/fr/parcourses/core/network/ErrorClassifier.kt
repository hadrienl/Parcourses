package fr.parcourses.core.network

import fr.parcourses.core.network.session.SecureStorageUnavailableException
import io.github.jan.supabase.auth.exception.AuthErrorCode
import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.auth.exception.NoSessionFoundException
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.postgrest.exception.PostgrestRestException
import kotlinx.coroutines.CancellationException
import java.io.IOException

/**
 * Classe toute exception rencontrée par le gateway.
 * L'annulation n'est jamais classée : l'appelant la relance telle quelle ([CancellationException]).
 */
internal fun Throwable.toRemoteError(): RemoteError =
    when (this) {
        is RemoteError -> {
            this
        }

        is PostgrestRestException -> {
            // Sans code PostgREST, le statut HTTP se perdrait.
            if (code == null) RemoteError.fromHttp(statusCode, this) else RemoteError.fromPostgrest(code, this)
        }

        is AuthRestException -> {
            classifyAuth(this)
        }

        is RestException -> {
            RemoteError.fromHttp(statusCode, this)
        }

        is NoSessionFoundException -> {
            RemoteError.Unauthorized(this)
        }

        is SecureStorageUnavailableException -> {
            RemoteError.SecureStorageLocked(this)
        }

        is IOException -> {
            RemoteError.Network(this)
        }

        else -> {
            RemoteError.Unexpected(this)
        }
    }

private const val HTTP_UNAUTHORIZED = 401
private const val HTTP_FORBIDDEN = 403

private val sessionGoneCodes =
    setOf(
        AuthErrorCode.RefreshTokenNotFound,
        AuthErrorCode.RefreshTokenAlreadyUsed,
        AuthErrorCode.SessionNotFound,
        AuthErrorCode.SessionExpired,
    )

/** La session ne reviendra pas : seul un nouveau compte anonyme permet de continuer. */
internal fun Throwable.isSessionGone(): Boolean =
    this is NoSessionFoundException || (this is AuthRestException && errorCode in sessionGoneCodes)

private fun classifyAuth(error: AuthRestException): RemoteError {
    if (error.isSessionGone()) return RemoteError.Unauthorized(error)
    // Côté Auth, 401 et 403 signifient une session refusée, jamais une donnée refusée.
    val status = error.statusCode
    return if (status == HTTP_UNAUTHORIZED || status == HTTP_FORBIDDEN ||
        error.errorCode == AuthErrorCode.UserNotFound
    ) {
        RemoteError.Unauthorized(error)
    } else {
        RemoteError.Server(status.toString(), error)
    }
}

/** Relance l'annulation, classe le reste. */
internal inline fun <T> mapped(block: () -> T): T =
    try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        throw e.toRemoteError()
    }
