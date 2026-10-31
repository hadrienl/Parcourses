package fr.parcourses.core.sorting

import org.junit.Assert.assertEquals
import org.junit.Test

class SortVectorCoverageTest {
    // Garde-fou : tous les fichiers JSON du dossier sont lus, aucun n'est ignoré.
    @Test
    fun loadsEveryVectorFile() {
        val files = SortVectors.dir.listFiles { f -> f.extension == "json" }.orEmpty()
        assert(files.size >= 35) { "vecteurs introuvables dans ${SortVectors.dir}" }
        assertEquals(
            files.size,
            SortVectors
                .all()
                .map { it.id }
                .distinct()
                .size,
        )
    }
}
