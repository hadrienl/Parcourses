package fr.parcourses.app

import android.content.Context
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

    /**
     * Le lien à relancer vers la tâche de Parcourses (#120), ou `null` si l'intention n'est pas un lien à suivre. Une
     * intention neuve et explicite (action, adresse, [MainActivity]) : rien d'autre de l'appelant n'est relancé.
     * `NEW_TASK` vise la tâche de Parcourses, `CLEAR_TOP | SINGLE_TOP` y remet l'instance ouverte au premier plan et lui
     * passe le lien par `onNewIntent`, sans seconde instance.
     */
    fun relayed(
        intent: Intent?,
        context: Context,
    ): Intent? =
        followed(intent)?.data?.let { data ->
            Intent(Intent.ACTION_VIEW, data, context, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }

    private fun followed(intent: Intent?): Intent? =
        intent?.takeIf {
            it.action == Intent.ACTION_VIEW && it.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0
        }
}
