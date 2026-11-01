package fr.parcourses.core.sorting

/** Matrice carrée des distances, aplatie dans un seul tableau (lignes contiguës). */
internal class DistanceMatrix(
    val size: Int,
) {
    val cells = LongArray(size * size)

    operator fun get(
        from: Int,
        to: Int,
    ): Long = cells[from * size + to]
}
