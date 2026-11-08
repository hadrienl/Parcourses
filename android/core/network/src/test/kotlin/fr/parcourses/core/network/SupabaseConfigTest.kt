@file:Suppress("ktlint:standard:max-line-length")

package fr.parcourses.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class SupabaseConfigTest {
    @Test
    fun refusesAnEmptyOrUnsafeEnvironment() {
        assertNull(SupabaseConfig.create("", ""))
        assertNull(SupabaseConfig.create(null, "k"))
        assertNull(SupabaseConfig.create("http://127.0.0.1:56321", ""))
        assertNull(SupabaseConfig.create("ftp://example.org", "k"))
        // `http` jamais vers un serveur distant.
        assertNull(SupabaseConfig.create("http://example.org", "k"))
        assertNull(SupabaseConfig.create("not a url", "k"))
    }

    @Test
    fun acceptsHttpsAndLocalCleartext() {
        assertNotNull(SupabaseConfig.create("https://abc.supabase.co", "k"))
        assertNotNull(SupabaseConfig.create("http://127.0.0.1:56321", "k"))
        assertNotNull(SupabaseConfig.create("http://10.0.2.2:56321", "k"))
        assertNotNull(SupabaseConfig.create("http://localhost:56321", "k"))
    }

    @Test
    fun normalizesTheTrailingSlashAndHidesTheKey() {
        val config = SupabaseConfig.create("https://abc.supabase.co/", "secret-key")!!
        assertEquals("https://abc.supabase.co", config.url)
        assertFalse(config.toString().contains("secret-key"))
    }

    @Test
    fun refusesSecretKeys() {
        assertNull(SupabaseConfig.create("https://abc.supabase.co", "sb_secret_abc"))
        val payload =
            java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(
                """{"role":"service_role"}""".toByteArray(),
            )
        assertNull(SupabaseConfig.create("https://abc.supabase.co", "eyJhbGciOiJIUzI1NiJ9.$payload.sig"))
        val anon =
            java.util.Base64
                .getUrlEncoder()
                .withoutPadding()
                .encodeToString("""{"role":"anon"}""".toByteArray())
        assertNotNull(SupabaseConfig.create("https://abc.supabase.co", "eyJhbGciOiJIUzI1NiJ9.$anon.sig"))
        assertNotNull(SupabaseConfig.create("https://abc.supabase.co", "sb_publishable_abc"))
    }
}
