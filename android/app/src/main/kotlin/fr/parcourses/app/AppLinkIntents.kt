package fr.parcourses.app

import android.content.Intent
import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.feature.shopping.live.LiveUpdateLinks

/**
 * Liens reçus par [MainActivity] : invitation (#87) et Live Update (#10 §8.1). Une intention rejouée depuis les apps
 * récentes (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`) n'est jamais suivie une seconde fois.
 */
internal object AppLinkIntents {
    /**
     * Jeton d'une invitation : `parcourses://invitation#<jeton>`, ou App Link `https://<httpsHost>/i/#<jeton>` (lot
     * 87.7). Le filtre du manifeste ne voit pas le fragment : [SharingDecisions.parseInvitationLink] fait foi.
     */
    fun invitationToken(
        intent: Intent?,
        httpsHost: String?,
    ): String? = followed(intent)?.dataString?.let { SharingDecisions.parseInvitationLink(it, httpsHost) }

    /** Visite à rouvrir : `parcourses://shopping/<visitId>`. */
    fun shoppingVisit(intent: Intent?): String? = followed(intent)?.let { LiveUpdateLinks.visitId(it.dataString) }

    private fun followed(intent: Intent?): Intent? =
        intent?.takeIf {
            it.action == Intent.ACTION_VIEW && it.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0
        }
}
