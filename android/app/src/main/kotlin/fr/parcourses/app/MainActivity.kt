package fr.parcourses.app

import android.app.ActivityManager
import android.content.Intent
import android.os.Build
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
        if (savedInstanceState == null && relayToOwnTask(intent)) return
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

    // `singleTop` : la Live Update ou le lien d'invitation touché pendant que l'app est ouverte arrive ici, comme un
    // lien relayé depuis la tâche d'une autre app (#120).
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
     * Lien ouvert par une autre app sans FLAG_ACTIVITY_NEW_TASK (navigateur intégré, #120) : cette instance est née
     * dans la tâche de l'appelant, et celle que l'on retrouve depuis les apps récentes ne montrerait pas le lien. Il
     * est relancé vers la tâche de Parcourses ([AppLinkIntents.relayed]), où l'instance ouverte le reçoit par
     * [onNewIntent], puis cette instance se ferme sans rien afficher ni suivre le lien. `true` si le lien est relayé.
     */
    private fun relayToOwnTask(intent: Intent?): Boolean {
        val relayed =
            AppLinkIntents
                .relayed(intent, this, container.invitationLinks.httpsHost)
                ?.takeUnless { isTaskRoot || isInOwnTask() }
        relayed?.let {
            startActivity(it)
            finish()
        }
        return relayed != null
    }

    /** Tâche de Parcourses : `appTasks` liste les tâches de l'app, pas celle d'une autre app qui nous héberge. */
    private fun isInOwnTask(): Boolean =
        getSystemService(ActivityManager::class.java).appTasks.any { task ->
            // La tâche peut disparaître entre la liste et sa lecture : `getTaskInfo` lève alors une exception.
            val info = runCatching { task.taskInfo }.getOrNull() ?: return@any false
            val id =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    info.taskId
                } else {
                    @Suppress("DEPRECATION") // seul identifiant de la tâche avant Android 10
                    info.persistentId
                }
            id == taskId
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
