package fr.parcourses.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import fr.parcourses.core.designsystem.ParcoursesTheme

/** Seule activité de l'app : le thème, puis la navigation. */
@OptIn(ExperimentalComposeUiApi::class)
class MainActivity : ComponentActivity() {
    private val container get() = (application as ParcoursesApp).container

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        // Sans état sauvegardé : lancement à froid, la seule occasion de reprendre une visite restée ouverte.
        val coldStart = savedInstanceState == null
        // Une recréation garde l'intention du lancement : le lien n'est suivi qu'une fois. Lancée par la Live Update,
        // l'app ouvre la pile du lien (`[Lists, Shopping]`) et non celle de la reprise au lancement.
        val linked = coldStart && offerLink(intent)
        setContent {
            ParcoursesTheme {
                // Les `testTag` deviennent des identifiants de ressource : UI Automator (Baseline Profile,
                // Macrobenchmark) les retrouve sur l'APK minifié. Les dialogues, fenêtres à part, n'en héritent pas.
                Box(Modifier.semantics { testTagsAsResourceId = true }) {
                    ParcoursesNavHost(container, coldStart = coldStart && !linked)
                }
            }
        }
    }

    // `singleTask` : la Live Update ou le lien d'invitation reçu pendant que l'app est ouverte arrive ici, même lancé
    // sans FLAG_ACTIVITY_NEW_TASK depuis la tâche d'une autre app (#120).
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        offerLink(intent)
    }

    override fun onStart() {
        super.onStart()
        container.onForeground()
    }

    /**
     * `true` si l'intention est un lien de la Live Update, transmis à la navigation. Une tâche ouverte par la
     * notification garde ce lien comme intention de départ : relancée depuis les apps récentes, elle ne le rejoue pas.
     */
    private fun offerLink(intent: Intent?): Boolean {
        // Invitation (#87) : `parcourses://invitation#<jeton>`, ou App Link https sur l'hôte configuré (lot 87.7). Le
        // jeton reste en mémoire ; l'intention est vidée pour qu'une recréation ne le rejoue pas.
        val token = AppLinkIntents.invitationToken(intent, container.invitationLinks.httpsHost)
        if (token != null) {
            container.offerInvitation(token)
            intent?.data = null
            return false
        }
        val visitId = AppLinkIntents.shoppingVisit(intent)
        visitId?.let(container::offerShoppingLink)
        return visitId != null
    }
}
