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
        // Une recréation garde l'intention du lancement : le lien n'est suivi qu'une fois.
        if (coldStart) offerLink(intent)
        setContent {
            ParcoursesTheme {
                ParcoursesNavHost(container, coldStart)
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

    private fun offerLink(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        LiveUpdateLinks.visitId(intent.dataString)?.let(container::offerShoppingLink)
    }
}
