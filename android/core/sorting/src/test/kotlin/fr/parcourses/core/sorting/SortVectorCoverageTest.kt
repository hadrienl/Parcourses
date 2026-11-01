package fr.parcourses.core.sorting

import fr.parcourses.core.model.SortStart
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
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

    @Test
    fun decodesStartLikeTheReference() {
        fun start(json: String) = SortVectors.start(Json.parseToJsonElement(json).jsonObject)
        assertEquals(SortStart.Entry, start("""{"entry": true, "product_id": "p-a"}"""))
        assertEquals(SortStart.Entry, start("""{"entry": false}"""))
        assertEquals(SortStart.Product("p-a"), start("""{"product_id": "p-a"}"""))
        assertThrows(NoSuchElementException::class.java) { start("{}") }
    }
}
