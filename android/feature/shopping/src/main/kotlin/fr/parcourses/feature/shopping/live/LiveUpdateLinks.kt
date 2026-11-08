package fr.parcourses.feature.shopping.live

import kotlin.uuid.Uuid

/**
 * Lien profond de la Live Update (#10 §8.1) : `parcourses://shopping/<visitId>` rouvre le mode courses de cette
 * visite, sur la pile `[Lists, Shopping]`.
 */
object LiveUpdateLinks {
    const val SCHEME = "parcourses"
    const val HOST = "shopping"

    fun shopping(visitId: String): String = "$SCHEME://$HOST/$visitId"

    /** Identifiant de visite d'un lien, en minuscules ; `null` pour tout autre lien (schéma, hôte, UUID invalide). */
    fun visitId(link: String?): String? {
        val prefix = "$SCHEME://$HOST/"
        if (link == null || !link.startsWith(prefix, ignoreCase = true)) return null
        val id = link.substring(prefix.length).trimEnd('/')
        return Uuid.parseOrNull(id)?.toString()
    }
}
