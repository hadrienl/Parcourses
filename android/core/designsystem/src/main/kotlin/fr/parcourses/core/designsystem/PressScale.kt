package fr.parcourses.core.designsystem

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue

/**
 * Échelle d'une ligne pendant un appui (#110) : elle s'enfonce légèrement tant que le doigt reste posé, annonce de
 * l'appui long. Aucune en mouvement réduit.
 */
@Composable
fun pressScale(interaction: InteractionSource): State<Float> {
    val pressed by interaction.collectIsPressedAsState()
    val reduced = Ticket.accessibility.reducedMotion
    return animateFloatAsState(
        if (pressed && !reduced) PRESSED_SCALE else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMediumLow),
        label = "press",
    )
}

/** Échelle d'une ligne enfoncée. */
private const val PRESSED_SCALE = 0.97f
