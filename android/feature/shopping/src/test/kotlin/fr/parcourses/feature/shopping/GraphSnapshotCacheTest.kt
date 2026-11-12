package fr.parcourses.feature.shopping

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.repository.GraphRepository
import fr.parcourses.core.network.dto.GraphSnapshotResponse
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

@RunWith(AndroidJUnit4::class)
class GraphSnapshotCacheTest : ShoppingTest() {
    private fun cache() = GraphSnapshotCache(graphs, gateway, clock)

    @Test
    fun refreshStoresTheRawPayloadAndDecodesIt() =
        runBlocking {
            val payload = learnedPayload(P1, P2, P3, version = 9)
            gateway!!.snapshot = { GraphSnapshotResponse.Payload(payload) }

            val loaded = cache().refresh(storeId)!!

            assertEquals(9L, loaded.version)
            assertEquals(800L, loaded.snapshot.confidenceQ)
            assertEquals(listOf(P1), loaded.snapshot.entries.map { it.productId })
            assertEquals(2, loaded.snapshot.edges.size)
            assertEquals(500L, loaded.params.confThresholdQ)
            // Le JSON brut est conservé tel quel, pas ré-encodé.
            assertEquals(payload, graphs.snapshot(storeId)!!.payload.decodeToString())
            assertEquals(9L, cache().cached(storeId)?.version)
        }

    @Test
    fun nothingNewOrUnknownStoreLeavesTheCacheAlone() =
        runBlocking {
            cacheSnapshot(learnedPayload(P1, P2))
            gateway!!.snapshot = { GraphSnapshotResponse.Unchanged }
            assertNull(cache().refresh(storeId))
            gateway!!.snapshot = { GraphSnapshotResponse.None }
            assertNull(cache().refresh(storeId))
            assertNotNull(cache().cached(storeId))
            assertEquals(listOf<Long?>(5L, 5L), gateway!!.knownVersions)
        }

    @Test
    fun anUnreadableOrUnknownFormatIsNeverStored() =
        runBlocking {
            gateway!!.snapshot = { GraphSnapshotResponse.Payload("pas du json") }
            assertNull(cache().refresh(storeId))
            gateway!!.snapshot = { GraphSnapshotResponse.Payload("""{"format_version":2}""") }
            assertNull(cache().refresh(storeId))
            assertNull(graphs.snapshot(storeId))
            assertNull(cache().cached(storeId))
        }

    @Test
    fun withoutAGatewayOnlyTheCacheAnswers() =
        runBlocking {
            gateway = null
            assertNull(GraphSnapshotCache(graphs, null, clock).refresh(storeId))
            cacheSnapshot(learnedPayload(P1, P2))
            assertTrue(GraphSnapshotCache(graphs, null, clock).cached(storeId) != null)
        }

    @Test
    fun onlyTheFiveMostRecentStoresAreKept() =
        runBlocking {
            val stores = (1..6).map { "00000000-0000-0000-0000-00000000010$it" }
            stores.forEachIndexed { index, id ->
                graphs.saveSnapshot(
                    id,
                    index.toLong(),
                    1,
                    800,
                    learnedPayload(P1, P2).encodeToByteArray(),
                    clock() + (index + 1).toLong().let { kotlin.time.Duration.parse("${it}s") },
                )
            }
            assertNull(graphs.snapshot(stores.first()))
            assertNotNull(graphs.snapshot(stores.last()))
        }

    @Test
    fun aStoreInUseIsNotEvictedForWantOfANewVersion() =
        runBlocking {
            // #54 : magasin habituel au graphe stable, puis cinq magasins de passage.
            val usual = "00000000-0000-0000-0000-000000000200"
            val passing = (1..5).map { "00000000-0000-0000-0000-00000000020$it" }
            val payload = learnedPayload(P1, P2).encodeToByteArray()
            graphs.saveSnapshot(usual, 1, 1, 800, payload, clock())
            passing.take(4).forEachIndexed { index, id ->
                graphs.saveSnapshot(id, 1, 1, 800, payload, clock() + (index + 1).seconds)
            }
            // Courses au magasin habituel : le serveur n'a rien de neuf, le cache sert.
            val later = GraphSnapshotCache(graphs, gateway) { clock() + 1.minutes }
            assertNotNull(later.cached(usual))

            graphs.saveSnapshot(passing.last(), 1, 1, 800, payload, clock() + 2.minutes)

            assertNotNull(graphs.snapshot(usual))
            assertNull(graphs.snapshot(passing.first()))
        }

    @Test
    fun aFailedTouchStillGivesTheCachedSnapshot() =
        runBlocking {
            cacheSnapshot(learnedPayload(P1, P2))
            val failing =
                object : GraphRepository by graphs {
                    override suspend fun touch(
                        storeId: String,
                        at: kotlin.time.Instant,
                    ): Unit = throw IllegalStateException("disque plein")
                }
            assertNotNull(GraphSnapshotCache(failing, gateway, clock).cached(storeId))
        }
}
