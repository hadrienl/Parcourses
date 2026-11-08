package fr.parcourses.core.data.repository

import fr.parcourses.core.database.CategorySeed
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.entity.CategoryEntity
import fr.parcourses.core.database.entity.GraphSnapshotEntity
import fr.parcourses.core.database.entity.ProductEntity
import fr.parcourses.core.database.entity.StoreEntity
import fr.parcourses.core.network.CategoryMap
import fr.parcourses.core.network.dto.CategoryRow
import kotlinx.coroutines.flow.Flow
import kotlin.time.Instant

/** Cache local du catalogue de produits, vide tant que la descente ne l'a pas rempli. */
interface ProductRepository {
    fun observeProducts(): Flow<List<ProductEntity>>

    suspend fun products(): List<ProductEntity>
}

class RoomProductRepository(
    private val db: ParcoursesDatabase,
) : ProductRepository {
    override fun observeProducts(): Flow<List<ProductEntity>> = db.products().observeAll()

    override suspend fun products(): List<ProductEntity> = db.products().getAll()
}

/** Catégories de rayon. */
interface CategoryRepository {
    /** Catégories triées par `(rank, id)`. */
    fun observeCategories(): Flow<List<CategoryEntity>>

    suspend fun categories(): List<CategoryEntity>

    /** Aligne la table sur le référentiel embarqué si sa version dépasse celle déjà appliquée. */
    suspend fun seedIfNeeded(): Boolean

    /**
     * Renseigne `remoteId` par slug. Le référentiel embarqué fait foi : aucune catégorie locale n'est ajoutée ni
     * supprimée, et une catégorie que le serveur ne connaît pas repasse à `null`.
     */
    suspend fun applyRemoteIds(rows: List<CategoryRow>)
}

class RoomCategoryRepository(
    private val db: ParcoursesDatabase,
    private val seed: () -> CategorySeed = CategorySeed::bundled,
) : CategoryRepository {
    override fun observeCategories(): Flow<List<CategoryEntity>> = db.categories().observeAll()

    override suspend fun categories(): List<CategoryEntity> = db.categories().getAll()

    override suspend fun seedIfNeeded(): Boolean = db.categories().seedIfNeeded(seed())

    override suspend fun applyRemoteIds(rows: List<CategoryRow>) {
        val map = CategoryMap(rows)
        for (category in db.categories().getAll()) {
            val remote = map.remoteId(category.slug)?.toInt()
            if (remote !=
                null
            ) {
                db.categories().setRemoteId(category.slug, remote)
            } else {
                db.categories().clearRemoteId(category.slug)
            }
        }
    }
}

/** Cache local des magasins. Aucune position n'est conservée. */
interface StoreRepository {
    suspend fun store(id: String): StoreEntity?

    /** Magasins déjà utilisés, du plus récent au plus ancien. */
    suspend fun recentStores(limit: Int): List<StoreEntity>

    /** [organicAisle] à `null` : inconnu ici, la valeur en cache est conservée. */
    suspend fun upsertStore(
        id: String,
        name: String,
        chain: String?,
        address: String?,
        organicAisle: Boolean?,
    )

    /** Valeur du serveur, plus fraîche que le cache. Sans effet si le magasin n'est pas en cache. */
    suspend fun updateOrganicAisle(
        id: String,
        organicAisle: Boolean,
    )

    suspend fun markUsed(
        id: String,
        at: Instant,
    )
}

class RoomStoreRepository(
    private val db: ParcoursesDatabase,
) : StoreRepository {
    override suspend fun store(id: String): StoreEntity? = db.stores().get(id)

    override suspend fun recentStores(limit: Int): List<StoreEntity> = db.stores().recent(limit)

    override suspend fun upsertStore(
        id: String,
        name: String,
        chain: String?,
        address: String?,
        organicAisle: Boolean?,
    ) {
        val known = db.stores().get(id)
        db.stores().upsert(
            StoreEntity(
                id = id,
                name = name,
                chain = chain,
                address = address,
                lastUsedAt = known?.lastUsedAt,
                organicAisle = organicAisle ?: known?.organicAisle ?: false,
            ),
        )
    }

    override suspend fun updateOrganicAisle(
        id: String,
        organicAisle: Boolean,
    ) {
        val known = db.stores().get(id) ?: return
        if (known.organicAisle != organicAisle) db.stores().upsert(known.copy(organicAisle = organicAisle))
    }

    override suspend fun markUsed(
        id: String,
        at: Instant,
    ) {
        if (db.stores().markUsed(id, at) == 0) throw RepositoryException.NotFound(id)
    }
}

/** Instantanés du graphe. Le contenu vient toujours du serveur. */
interface GraphRepository {
    suspend fun snapshot(storeId: String): GraphSnapshotEntity?

    /** Remplace l'instantané du magasin et ne garde que les plus récents (LRU sur `fetchedAt`). */
    @Suppress("LongParameterList")
    suspend fun saveSnapshot(
        storeId: String,
        snapshotVersion: Long,
        paramsVersion: Long,
        confidenceQ: Long,
        payload: ByteArray,
        at: Instant,
    )
}

class RoomGraphRepository(
    private val db: ParcoursesDatabase,
) : GraphRepository {
    override suspend fun snapshot(storeId: String): GraphSnapshotEntity? = db.graphSnapshots().get(storeId)

    override suspend fun saveSnapshot(
        storeId: String,
        snapshotVersion: Long,
        paramsVersion: Long,
        confidenceQ: Long,
        payload: ByteArray,
        at: Instant,
    ) {
        db.graphSnapshots().saveSnapshot(
            GraphSnapshotEntity(storeId, snapshotVersion, paramsVersion, confidenceQ, at, payload),
        )
    }
}
