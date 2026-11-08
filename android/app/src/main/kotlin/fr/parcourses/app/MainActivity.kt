package fr.parcourses.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.feature.shopping.live.LiveUpdateLinks

/** Seule activité de l'app : le thème, puis la navigation. */
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
                ParcoursesNavHost(container, coldStart = coldStart && !linked)
            }
        }
    }

    // `singleTop` : la Live Update touchée pendant que l'app est ouverte arrive ici.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        offerLink(intent)
    }

    override fun onStart() {
        super.onStart()
        container.onForeground()
    }

    /** `true` si l'intention est un lien de la Live Update, transmis à la navigation. */
    private fun offerLink(intent: Intent?): Boolean {
        val visitId = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.let { LiveUpdateLinks.visitId(it.dataString) }
        visitId?.let(container::offerShoppingLink)
        return visitId != null
    }
}
