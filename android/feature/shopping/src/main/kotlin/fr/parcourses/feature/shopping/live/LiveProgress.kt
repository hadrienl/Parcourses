package fr.parcourses.feature.shopping.live

/**
 * Barre de progression de la Live Update, indépendante d'Android pour être testée seule.
 *
 * La barre suit le trajet : d'abord les articles déjà pris, puis ceux qui restent, dans l'ordre affiché. Chaque
 * article y occupe [UNIT] unités ; un segment couvre une suite d'articles du même rayon (un par rayon en ordre
 * générique), un point marque le milieu de chaque article quand il y en a [MAX_POINTS] ou moins. La progression
 * s'arrête à la fin du dernier article pris.
 */
data class LiveProgress(
    val segments: List<Segment>,
    val points: List<Point>,
    val progress: Int,
    val max: Int,
) {
    /** [colorIndex] : place dans [LIVE_PALETTE], jamais la même que celle du segment voisin. */
    data class Segment(
        val length: Int,
        val colorIndex: Int,
    )

    data class Point(
        val position: Int,
        val colorIndex: Int,
    )

    companion object {
        /** Deux unités par article : un point tombe au milieu, sur un entier. */
        const val UNIT = 2

        /** Au-delà, des points serrés ne se distinguent plus (#10 §9). */
        const val MAX_POINTS = 30

        /** `Notification.ProgressStyle` ne compte que les 15 premiers segments dans sa longueur. */
        const val MAX_SEGMENTS = 15

        fun of(state: ShoppingLiveState): LiveProgress {
            val route = state.checked + state.pending
            val segments = segmentsOf(route)
            // Un point prend la couleur du segment de son article.
            val pointColors = segments.flatMap { segment -> List(segment.length / UNIT) { segment.colorIndex } }
            val points =
                if (route.size <= MAX_POINTS) {
                    pointColors.mapIndexed { index, color -> Point(index * UNIT + UNIT / 2, color) }
                } else {
                    emptyList()
                }
            return LiveProgress(segments, points, state.checked.size * UNIT, route.size * UNIT)
        }

        private fun segmentsOf(route: List<LiveItem>): List<Segment> {
            val runs = mutableListOf<MutableList<LiveItem>>()
            route.forEach { item ->
                val last = runs.lastOrNull()
                if (last != null && last.first().aisleId == item.aisleId) last += item else runs += mutableListOf(item)
            }
            // Trop de rayons : les derniers rejoignent le quinzième, la longueur totale reste juste.
            val kept: MutableList<List<LiveItem>> = runs.take(MAX_SEGMENTS - 1).toMutableList()
            if (runs.size >= MAX_SEGMENTS) kept += runs.drop(MAX_SEGMENTS - 1).flatten()
            var previous = -1
            return kept.map { items ->
                var color = Math.floorMod(items.first().aisleIndex, LIVE_PALETTE.size)
                if (color == previous) color = (color + 1) % LIVE_PALETTE.size
                previous = color
                Segment(items.size * UNIT, color)
            }
        }
    }
}

/** Couleurs des rayons, tirées de la palette de base (#6) ; le système en ajuste le contraste au fond. */
val LIVE_PALETTE: List<Int> =
    listOf(
        0xFF2E6B4F.toInt(),
        0xFFB4552D.toInt(),
        0xFF3A6EA5.toInt(),
        0xFFC49A2C.toInt(),
        0xFF7B4B94.toInt(),
        0xFF2C8C8C.toInt(),
    )
