package fr.parcourses.core.network

import fr.parcourses.core.network.session.SecureStorageUnavailableException
import io.github.jan.supabase.auth.exception.AuthErrorCode
import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.auth.exception.NoSessionFoundException
import io.github.jan.supabase.exceptions.HttpRequestException
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.postgrest.exception.PostgrestRestException
import kotlinx.coroutines.CancellationException
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException

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
            RemoteError.Unauthorized(this, noLocalSession = true)
        }

        is SecureStorageUnavailableException -> {
            RemoteError.SecureStorageLocked(this)
        }

        is IOException -> {
            RemoteError.Network(this, notSent = isNotSent())
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
    // Le code GoTrue est gardé : seuls certains prouvent qu'un compte a été supprimé (#68).
    val code = error.errorCode?.value
    if (error.isSessionGone()) return RemoteError.Unauthorized(error, code)
    // Côté Auth, 401 et 403 signifient une session refusée, jamais une donnée refusée.
    val status = error.statusCode
    return if (status == HTTP_UNAUTHORIZED || status == HTTP_FORBIDDEN ||
        error.errorCode == AuthErrorCode.UserNotFound
    ) {
        RemoteError.Unauthorized(error, code)
    } else {
        RemoteError.Server(status.toString(), error)
    }
}

/**
 * La requête n'a jamais quitté l'appareil. supabase-kt remplace l'erreur du transport par une `HttpRequestException`
 * sans cause, qui ne garde que son message : [NotSentInterceptor] y inscrit [RequestNotSentException.MARKER].
 */
internal fun Throwable.isNotSent(): Boolean =
    generateSequence(this) { it.cause }.any { error ->
        error.isNotSentCause() ||
            error is RequestNotSentException ||
            (error is HttpRequestException && error.message.orEmpty().contains(RequestNotSentException.MARKER))
    }

/** Hôte introuvable, connexion refusée, pas de route : aucun octet n'est parti. Un délai, lui, ne prouve rien. */
internal fun Throwable.isNotSentCause(): Boolean =
    this is UnknownHostException || this is ConnectException || this is NoRouteToHostException

/** Relance l'annulation, classe le reste. */
@Suppress("TooGenericExceptionCaught")
internal inline fun <T> mapped(block: () -> T): T =
    try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        throw e.toRemoteError()
    }
