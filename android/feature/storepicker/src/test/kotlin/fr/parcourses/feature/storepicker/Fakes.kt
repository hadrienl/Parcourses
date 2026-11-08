package fr.parcourses.feature.storepicker

import fr.parcourses.core.data.repository.StoreRepository
import fr.parcourses.core.database.entity.StoreEntity
import fr.parcourses.core.location.LocationAuthorization
import fr.parcourses.core.location.LocationFix
import fr.parcourses.core.location.LocationProvider
import fr.parcourses.core.location.LocationResult
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.dto.NearbyStoreRow
import fr.parcourses.core.network.dto.StoreSearchRow
import java.lang.reflect.Proxy
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Position simulée : le test fixe l'autorisation et le point, et compte les lectures. */
class FakeLocationProvider(
    override var authorization: LocationAuthorization = LocationAuthorization.Precise,
    var result: suspend () -> LocationResult = { LocationResult.Fix(fix()) },
) : LocationProvider {
    var reads = 0

    override suspend fun currentFix(): LocationResult {
        reads++
        return result()
    }

    companion object {
        fun fix(accuracy: Double = 20.0) = LocationFix(48.85, 2.35, accuracy, timestampMillis = 0)
    }
}

/** Seules les deux RPC de magasins sont simulées ; tout autre appel est une erreur du test. */
class FakeGateway(
    var nearby: suspend (
        lat: Double,
        lng: Double,
        radius: Int,
        max: Int,
    ) -> List<NearbyStoreRow> = { _, _, _, _ -> emptyList() },
    var search: suspend (query: String, limit: Int) -> List<StoreSearchRow> = { _, _ -> emptyList() },
) : RemoteGateway by unsupported() {
    val nearbyCalls = mutableListOf<Triple<Double, Double, Int>>()
    val searchCalls = mutableListOf<Pair<String, Int>>()

    override suspend fun nearbyStores(
        lat: Double,
        lng: Double,
        radiusM: Int,
        maxResults: Int,
    ): List<NearbyStoreRow> {
        nearbyCalls += Triple(lat, lng, radiusM)
        return nearby(lat, lng, radiusM, maxResults)
    }

    override suspend fun searchStores(
        query: String,
        limit: Int,
    ): List<StoreSearchRow> {
        searchCalls += query to limit
        return search(query, limit)
    }

    private companion object {
        fun unsupported(): RemoteGateway =
            Proxy.newProxyInstance(
                RemoteGateway::class.java.classLoader,
                arrayOf(RemoteGateway::class.java),
            ) { _, method, _ -> throw UnsupportedOperationException(method.name) } as RemoteGateway
    }
}

class FakeStoreRepository : StoreRepository {
    val cache = linkedMapOf<String, StoreEntity>()
    var failWrites = false
    var upserts = 0

    override suspend fun store(id: String) = cache[id]

    override suspend fun recentStores(limit: Int) =
        cache.values
            .filter { it.lastUsedAt != null }
            .sortedByDescending { it.lastUsedAt }
            .take(limit)

    override suspend fun upsertStore(
        id: String,
        name: String,
        chain: String?,
        address: String?,
        organicAisle: Boolean?,
    ) {
        check(!failWrites) { "disque plein" }
        upserts++
        val known = cache[id]
        cache[id] =
            StoreEntity(id, name, chain, address, known?.lastUsedAt, organicAisle ?: known?.organicAisle ?: false)
    }

    override suspend fun updateOrganicAisle(
        id: String,
        organicAisle: Boolean,
    ) = Unit

    override suspend fun markUsed(
        id: String,
        at: Instant,
    ) {
        val known = cache[id] ?: error("inconnu")
        cache[id] = known.copy(lastUsedAt = at)
    }
}

fun nearbyRow(
    name: String,
    distanceM: Double,
    id: Uuid = Uuid.random(),
    organic: Boolean? = null,
) = NearbyStoreRow(id, name, chain = null, address = "1 rue du Test", distanceM = distanceM, organicAisle = organic)

fun searchRow(
    name: String,
    id: Uuid = Uuid.random(),
) = StoreSearchRow(id, name, chain = null, address = "2 avenue du Test")
