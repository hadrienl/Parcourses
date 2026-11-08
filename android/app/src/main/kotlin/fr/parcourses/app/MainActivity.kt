package fr.parcourses.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import fr.parcourses.core.designsystem.ParcoursesTheme

/** Seule activité de l'app : le thème, puis la navigation. */
class MainActivity : ComponentActivity() {
    private val container get() = (application as ParcoursesApp).container

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        // Sans état sauvegardé : lancement à froid, la seule occasion de reprendre une visite restée ouverte.
        val coldStart = savedInstanceState == null
        setContent {
            ParcoursesTheme {
                ParcoursesNavHost(container, coldStart)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        container.onForeground()
    }
}
