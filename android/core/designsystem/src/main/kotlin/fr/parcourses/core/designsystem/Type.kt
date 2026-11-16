package fr.parcourses.core.designsystem

import androidx.compose.material3.Typography
import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/**
 * JetBrains Mono embarquée (`shared.typography.mono`), version sans ligatures (« NL ») : une liste de courses n'a que
 * faire de « -> » fondu en flèche. Licence SIL OFL 1.1 (`assets/licenses/JetBrainsMono-OFL.txt`). Quatre graisses :
 * 400 (texte), 500 (article), 700 (suivant, rayon), 800 (titre, total).
 */
val MonoFamily =
    FontFamily(
        Font(R.font.jetbrains_mono_nl_regular, FontWeight.Normal),
        Font(R.font.jetbrains_mono_nl_medium, FontWeight.Medium),
        Font(R.font.jetbrains_mono_nl_bold, FontWeight.Bold),
        Font(R.font.jetbrains_mono_nl_extrabold, FontWeight.ExtraBold),
    )

/** Styles du ticket (`shared.typography`). Toutes les tailles suivent l'échelle de police du système, jusqu'à 200 %. */
@Immutable
object TicketType {
    /** Compteur « RESTE 05 ». */
    val total =
        TextStyle(
            fontFamily = MonoFamily,
            fontWeight = FontWeight.ExtraBold,
            fontSize = 52.sp,
            lineHeight = 56.sp,
            letterSpacing = (-0.03).em,
        )

    /** Titre du ticket, en capitales. */
    val title =
        TextStyle(
            fontFamily = MonoFamily,
            fontWeight = FontWeight.ExtraBold,
            fontSize = 26.sp,
            lineHeight = 32.sp,
            letterSpacing = 0.04.em,
        )

    /** Article suivant. */
    val itemNext =
        TextStyle(fontFamily = MonoFamily, fontWeight = FontWeight.Bold, fontSize = 20.sp, lineHeight = 26.sp)

    val item = TextStyle(fontFamily = MonoFamily, fontWeight = FontWeight.Medium, fontSize = 17.sp, lineHeight = 23.sp)

    /** Nom du rayon et petites étiquettes (« RESTE »), en capitales. */
    val aisle =
        TextStyle(
            fontFamily = MonoFamily,
            fontWeight = FontWeight.Bold,
            fontSize = 12.sp,
            lineHeight = 16.sp,
            letterSpacing = 0.12.em,
        )

    /** Méta du ticket (date, magasin, connaissance du trajet). */
    val meta = TextStyle(fontFamily = MonoFamily, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 18.sp)

    /** Quantité, après les pointillés. */
    val quantity =
        TextStyle(fontFamily = MonoFamily, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp)
}

/**
 * Typographie Material : le ticket est en mono (titres, corps), les commandes (boutons, puces, barre d'annulation)
 * restent dans la police du système, comme dans la maquette Android.
 */
internal val ParcoursesTypography: Typography =
    Typography().run {
        copy(
            displayLarge = displayLarge.copy(fontFamily = MonoFamily),
            displayMedium = displayMedium.copy(fontFamily = MonoFamily),
            displaySmall = displaySmall.copy(fontFamily = MonoFamily, fontWeight = FontWeight.ExtraBold),
            headlineLarge = headlineLarge.copy(fontFamily = MonoFamily),
            headlineMedium = headlineMedium.copy(fontFamily = MonoFamily),
            headlineSmall = headlineSmall.copy(fontFamily = MonoFamily, fontWeight = FontWeight.Bold),
            titleLarge = titleLarge.copy(fontFamily = MonoFamily, fontWeight = FontWeight.ExtraBold),
            titleMedium = titleMedium.copy(fontFamily = MonoFamily, fontWeight = FontWeight.Bold),
            titleSmall = titleSmall.copy(fontFamily = MonoFamily, fontWeight = FontWeight.Bold),
            bodyLarge = bodyLarge.copy(fontFamily = MonoFamily),
            bodyMedium = bodyMedium.copy(fontFamily = MonoFamily),
            bodySmall = bodySmall.copy(fontFamily = MonoFamily),
        )
    }
