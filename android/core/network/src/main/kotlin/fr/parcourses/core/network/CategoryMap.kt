package fr.parcourses.core.network

import fr.parcourses.core.network.dto.CategoryRow
import kotlin.time.Duration.Companion.hours
import kotlin.time.Instant

/**
 * Correspondance entre les identifiants partagés (`shared/categories/`, slug serveur) et l'`Int` serveur,
 * qui ne doit jamais être écrit en dur ni sortir du gateway.
 */
class CategoryMap(
    rows: List<CategoryRow>,
    missingSlugs: Map<String, Instant> = emptyMap(),
) {
    private val idsBySlug: Map<String, Short> = rows.reversed().associate { it.slug to it.id }
    private val slugsById: Map<Short, String> = rows.reversed().associate { it.id to it.slug }

    /** Cache négatif : sans lui, chaque coche d'un slug inconnu relirait la table. */
    private val _missingSlugs = missingSlugs.toMutableMap()
    val missingSlugs: Map<String, Instant> get() = _missingSlugs

    fun remoteId(slug: String): Short? = idsBySlug[slug]

    fun slug(remoteId: Short): String? = slugsById[remoteId]

    fun shouldReload(
        slug: String,
        now: Instant,
    ): Boolean {
        if (idsBySlug.containsKey(slug)) return false
        val since = _missingSlugs[slug] ?: return true
        return now - since >= MISSING_SLUG_LIFETIME
    }

    fun markMissing(
        slug: String,
        at: Instant,
    ) {
        _missingSlugs[slug] = at
    }

    companion object {
        /** Délai avant de relire la table pour un slug qu'elle ne connaissait pas. */
        val MISSING_SLUG_LIFETIME = 1.hours
    }
}
