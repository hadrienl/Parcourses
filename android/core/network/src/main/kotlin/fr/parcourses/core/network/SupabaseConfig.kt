package fr.parcourses.core.network

import java.net.URI
import java.util.Base64

/**
 * Adresse et clé publique (publishable) de l'environnement Supabase, injectées par `BuildConfig`.
 * Seule la clé publique est embarquée : jamais de `service_role` (#10, §6).
 */
class SupabaseConfig private constructor(
    val url: String,
    val publishableKey: String,
) {
    // La clé ne doit jamais sortir dans un journal.
    override fun toString(): String = "SupabaseConfig(url=$url)"

    override fun equals(other: Any?): Boolean =
        other is SupabaseConfig && other.url == url && other.publishableKey == publishableKey

    override fun hashCode(): Int = 31 * url.hashCode() + publishableKey.hashCode()

    companion object {
        /**
         * `http` n'est admis que vers la machine elle-même ou vers l'hôte de l'émulateur (`10.0.2.2`),
         * jamais vers un serveur distant. Aligné sur le `network_security_config` de debug (test dans `:app`).
         */
        val CLEARTEXT_HOSTS: Set<String> = setOf("127.0.0.1", "localhost", "[::1]", "10.0.2.2")

        /** `null` si l'environnement n'est pas renseigné, non sûr, ou si la clé est secrète. */
        @Suppress("ReturnCount")
        fun create(
            url: String?,
            publishableKey: String?,
        ): SupabaseConfig? {
            if (url.isNullOrBlank() || publishableKey.isNullOrBlank()) return null
            // Une clé secrète n'a rien à faire dans une app : refusée, jamais embarquée.
            if (isSecretKey(publishableKey.trim())) return null
            val uri = runCatching { URI(url.trim()) }.getOrNull() ?: return null
            val host = uri.host ?: return null
            val allowed = uri.scheme == "https" || (uri.scheme == "http" && host in CLEARTEXT_HOSTS)
            if (!allowed) return null
            return SupabaseConfig(url.trim().trimEnd('/'), publishableKey.trim())
        }

        private fun isSecretKey(key: String): Boolean {
            val payload = key.split('.').getOrNull(1)
            val decoded =
                payload?.let { runCatching { String(Base64.getUrlDecoder().decode(it.trimEnd('='))) }.getOrNull() }
            // Ancien format : JWT dont le rôle est `service_role`.
            return key.startsWith("sb_secret_") ||
                (decoded != null && Regex(""""role"\s*:\s*"service_role"""").containsMatchIn(decoded))
        }
    }
}
