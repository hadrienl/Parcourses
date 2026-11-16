package fr.parcourses.core.designsystem

import androidx.compose.runtime.Immutable

/** Article ouvert dans le panneau (#110, même nom qu'iOS) : son identifiant, son libellé et sa quantité. */
@Immutable
data class ItemEditTarget(
    val id: String,
    val label: String,
    val quantity: String?,
)
