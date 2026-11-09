package fr.parcourses.core.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable

/**
 * Palette Material tirée des tokens B3 : le papier fait les surfaces, l'encre le texte, l'accent les actions. Les
 * conteneurs (dialogues, feuilles, champs) prennent le bord du papier, sans teinte d'élévation.
 */
internal fun TicketColors.toColorScheme(dark: Boolean): ColorScheme {
    val base = if (dark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = accent,
        onPrimary = onAccent,
        primaryContainer = paperEdge,
        onPrimaryContainer = ink,
        secondary = inkMuted,
        onSecondary = paper,
        secondaryContainer = paperEdge,
        onSecondaryContainer = ink,
        tertiary = accent,
        onTertiary = onAccent,
        background = desk,
        onBackground = ink,
        surface = paper,
        onSurface = ink,
        surfaceVariant = paperEdge,
        onSurfaceVariant = inkMuted,
        surfaceTint = paper,
        surfaceBright = paper,
        surfaceDim = paperEdge,
        surfaceContainerLowest = paper,
        surfaceContainerLow = paper,
        surfaceContainer = paperEdge,
        surfaceContainerHigh = paperEdge,
        surfaceContainerHighest = paperEdge,
        inverseSurface = ink,
        inverseOnSurface = paper,
        inversePrimary = inverseAccent,
        outline = inkMuted,
        outlineVariant = threadIdle,
        error = destructive,
        onError = paper,
        scrim = ink,
    )
}

/**
 * Thème de Parcourses : direction B3 « Ticket filé » (#6). Palette de la marque, sans couleur dynamique : il n'y a pas
 * encore d'écran de réglages pour la proposer en option (#6, question 3). [accessibility] est lu sur le système ; les
 * tests le fixent.
 */
@Composable
fun ParcoursesTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    accessibility: AccessibilityPreferences =
        AccessibilityPreferences(
            reducedMotion = rememberReducedMotion(),
            highContrast = rememberHighContrast(),
        ),
    content: @Composable () -> Unit,
) {
    val colors = if (darkTheme) DarkTicketColors else LightTicketColors
    CompositionLocalProvider(
        LocalTicketColors provides colors,
        LocalAccessibilityPreferences provides accessibility,
    ) {
        MaterialTheme(
            colorScheme = colors.toColorScheme(darkTheme),
            typography = ParcoursesTypography,
            content = content,
        )
    }
}

/** Accès aux tokens du thème courant. */
object Ticket {
    val colors: TicketColors
        @Composable @ReadOnlyComposable
        get() = LocalTicketColors.current

    val accessibility: AccessibilityPreferences
        @Composable @ReadOnlyComposable
        get() = LocalAccessibilityPreferences.current
}
