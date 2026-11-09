package fr.parcourses.core.designsystem

import androidx.annotation.DrawableRes
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Couleurs de la direction B3 « Ticket filé » (#6, `design/tokens-ticket-v2.json`, variante `ticketFile`). Mêmes noms
 * que les tokens et qu'iOS. [desk] (le fond autour du ticket) et [destructive] ne sont pas dans les tokens de couleur
 * d'origine : [desk] vient de la maquette (`--desk`), [destructive] des teintes iOS du lot 9.12 (#60).
 */
@Immutable
data class TicketColors(
    val desk: Color,
    val paper: Color,
    val paperEdge: Color,
    val ink: Color,
    val inkMuted: Color,
    val accent: Color,
    val onAccent: Color,
    val thread: Color,
    val threadIdle: Color,
    /** Fil inactif et perles vides en contraste élevé : au moins 3:1 sur le papier. */
    val threadIdleHighContrast: Color,
    val checked: Color,
    /** Action destructive (« Les retirer de la liste ») : au moins 4,5:1 sur le papier. */
    val destructive: Color,
    /** Accent du thème opposé : action de la barre « Annuler », posée sur l'encre. */
    val inverseAccent: Color,
    val aisle: AisleColors,
) {
    /** Couleur du rayon [categoryId] : trait de l'icône et anneau du nœud seulement, jamais du texte. */
    fun aisleColor(categoryId: String): Color =
        when (AisleFamily.of(categoryId)) {
            AisleFamily.Fresh -> aisle.fresh
            AisleFamily.Dairy -> aisle.dairy
            AisleFamily.Grocery -> aisle.grocery
            AisleFamily.Hygiene -> aisle.hygiene
            AisleFamily.Bio -> aisle.bio
            AisleFamily.Other -> inkMuted
        }
}

@Immutable
data class AisleColors(
    val fresh: Color,
    val dairy: Color,
    val grocery: Color,
    val hygiene: Color,
    val bio: Color,
)

val LightTicketColors =
    TicketColors(
        desk = Color(0xFFE3DCCF),
        paper = Color(0xFFFBF7F0),
        paperEdge = Color(0xFFEAE2D3),
        ink = Color(0xFF1A1C22),
        inkMuted = Color(0xFF545866),
        accent = Color(0xFF2340C8),
        onAccent = Color(0xFFFFFFFF),
        thread = Color(0xFF2340C8),
        threadIdle = Color(0xFFD5CEC0),
        threadIdleHighContrast = Color(0xFF8A8478),
        checked = Color(0xFF545866),
        destructive = Color(0xFFD70015),
        inverseAccent = Color(0xFF8FA6FF),
        aisle =
            AisleColors(
                fresh = Color(0xFF1F7A44),
                dairy = Color(0xFF2A6FB0),
                grocery = Color(0xFFA3520A),
                hygiene = Color(0xFF8A3FA0),
                bio = Color(0xFF4F6F12),
            ),
    )

val DarkTicketColors =
    TicketColors(
        desk = Color(0xFF08090C),
        paper = Color(0xFF12141A),
        paperEdge = Color(0xFF232631),
        ink = Color(0xFFECEEF4),
        inkMuted = Color(0xFFA6ABBA),
        accent = Color(0xFF8FA6FF),
        onAccent = Color(0xFF0B1550),
        thread = Color(0xFF8FA6FF),
        threadIdle = Color(0xFF353A48),
        threadIdleHighContrast = Color(0xFF7A8094),
        checked = Color(0xFFA6ABBA),
        destructive = Color(0xFFFF6961),
        inverseAccent = Color(0xFF2340C8),
        aisle =
            AisleColors(
                fresh = Color(0xFF6FD39A),
                dairy = Color(0xFF86BEF2),
                grocery = Color(0xFFF2B06A),
                hygiene = Color(0xFFE0A3F0),
                bio = Color(0xFFC3DC6A),
            ),
    )

/**
 * Famille de couleur d'un rayon. Les tokens n'en donnent que cinq : la table est commune à iOS et Android
 * (`shared.categoryIcon.family` dans `design/tokens-ticket-v2.json`). `other`, et tout rayon inconnu, prend `inkMuted`.
 */
enum class AisleFamily {
    Fresh,
    Dairy,
    Grocery,
    Hygiene,
    Bio,
    Other,
    ;

    companion object {
        private val families =
            mapOf(
                "produce" to Fresh,
                "bakery" to Fresh,
                "butcher" to Fresh,
                "deli" to Fresh,
                "seafood" to Fresh,
                "cheese" to Dairy,
                "dairy" to Dairy,
                "frozen" to Dairy,
                "beverages" to Dairy,
                "savory-grocery" to Grocery,
                "world-food" to Grocery,
                "breakfast" to Grocery,
                "sweet-grocery" to Grocery,
                "snacks" to Grocery,
                "alcohol" to Grocery,
                "baby" to Hygiene,
                "hygiene" to Hygiene,
                "household" to Hygiene,
                "pets" to Hygiene,
                "bio" to Bio,
            )

        fun of(categoryId: String): AisleFamily = families[categoryId] ?: Other
    }
}

/** Icônes au trait des rayons (`design/icons/categories/<id>.svg`, converties par `sync-category-icons.py`). */
private val categoryIcons =
    mapOf(
        "produce" to R.drawable.ic_cat_produce,
        "bakery" to R.drawable.ic_cat_bakery,
        "butcher" to R.drawable.ic_cat_butcher,
        "deli" to R.drawable.ic_cat_deli,
        "seafood" to R.drawable.ic_cat_seafood,
        "cheese" to R.drawable.ic_cat_cheese,
        "dairy" to R.drawable.ic_cat_dairy,
        "savory-grocery" to R.drawable.ic_cat_savory_grocery,
        "bio" to R.drawable.ic_cat_bio,
        "world-food" to R.drawable.ic_cat_world_food,
        "breakfast" to R.drawable.ic_cat_breakfast,
        "sweet-grocery" to R.drawable.ic_cat_sweet_grocery,
        "snacks" to R.drawable.ic_cat_snacks,
        "beverages" to R.drawable.ic_cat_beverages,
        "alcohol" to R.drawable.ic_cat_alcohol,
        "frozen" to R.drawable.ic_cat_frozen,
        "baby" to R.drawable.ic_cat_baby,
        "hygiene" to R.drawable.ic_cat_hygiene,
        "household" to R.drawable.ic_cat_household,
        "pets" to R.drawable.ic_cat_pets,
    )

/** Icône au trait du rayon ; `other` pour un rayon inconnu. Décorative. */
@DrawableRes
fun categoryIcon(categoryId: String): Int = categoryIcons[categoryId] ?: R.drawable.ic_cat_other

/** Dimensions partagées (`shared.size`, `shared.structure`, `shared.space`). */
object TicketDimens {
    val rowMin = 56.dp
    val touchMin = 48.dp
    val checkBox = 28.dp
    val primaryAction = 56.dp
    val threadGutter = 28.dp
    val threadWidth = 3.dp

    /** Contraste accru : fil plus épais (iOS : même valeur). */
    val threadWidthHighContrast = 5.dp
    val bead = 14.dp
    val beadNext = 18.dp
    val aisleNode = 28.dp
    val aisleIcon = 20.dp
    val radius = 8.dp
    val spaceXs = 8.dp
    val spaceS = 12.dp
    val spaceM = 16.dp
    val spaceL = 24.dp

    /** Marge du ticket sur le bureau. */
    val ticketMargin = 12.dp
}

val LocalTicketColors = staticCompositionLocalOf { LightTicketColors }
