package fr.parcourses.core.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Palette de base ; les tokens définitifs de #6 arriveront en A11.
private val LightColors =
    lightColorScheme(
        primary = Color(0xFF2E6B4F),
        onPrimary = Color(0xFFFFFFFF),
        secondary = Color(0xFFB4552D),
        background = Color(0xFFFBF8F3),
        surface = Color(0xFFFBF8F3),
    )

private val DarkColors =
    darkColorScheme(
        primary = Color(0xFF8FD3B0),
        onPrimary = Color(0xFF003824),
        secondary = Color(0xFFFFB595),
        background = Color(0xFF151311),
        surface = Color(0xFF151311),
    )

// Thème Material 3 de Parcourses. Couleur dynamique désactivée par défaut (#10, §16).
@Composable
fun ParcoursesTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content,
    )
}
