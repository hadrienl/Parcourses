package fr.parcourses.core.database

import androidx.room3.ColumnTypeConverters
import androidx.room3.Database
import androidx.room3.ExperimentalRoomApi
import androidx.room3.RoomDatabase
import androidx.room3.RoomWarnings
import fr.parcourses.core.database.dao.CategoryDao
import fr.parcourses.core.database.dao.CheckDao
import fr.parcourses.core.database.dao.GraphSnapshotDao
import fr.parcourses.core.database.dao.ListItemDao
import fr.parcourses.core.database.dao.OutboxDao
import fr.parcourses.core.database.dao.ProductDao
import fr.parcourses.core.database.dao.ShoppingListDao
import fr.parcourses.core.database.dao.StoreDao
import fr.parcourses.core.database.dao.VisitDao
import fr.parcourses.core.database.entity.CategoryEntity
import fr.parcourses.core.database.entity.CategorySeedStateEntity
import fr.parcourses.core.database.entity.CheckEntity
import fr.parcourses.core.database.entity.GraphSnapshotEntity
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.OutboxEntryEntity
import fr.parcourses.core.database.entity.ProductEntity
import fr.parcourses.core.database.entity.ShoppingListEntity
import fr.parcourses.core.database.entity.StoreEntity
import fr.parcourses.core.database.entity.VisitEntity

// Projet Android seul : pas de `@ConstructedBy` (réservé au multiplateforme), Room retrouve `_Impl` par la classe.

/** Base locale, source de vérité de l'app (#10, §2.2). Le schéma exporté est dans `schemas/`. */
@Database(
    entities = [
        ShoppingListEntity::class,
        ListItemEntity::class,
        VisitEntity::class,
        CheckEntity::class,
        StoreEntity::class,
        GraphSnapshotEntity::class,
        ProductEntity::class,
        CategoryEntity::class,
        CategorySeedStateEntity::class,
        OutboxEntryEntity::class,
    ],
    version = ParcoursesDatabase.VERSION,
    exportSchema = true,
)
@ColumnTypeConverters(InstantConverters::class)
@OptIn(ExperimentalRoomApi::class)
@Suppress(RoomWarnings.NO_DATABASE_CONSTRUCTOR)
abstract class ParcoursesDatabase : RoomDatabase() {
    abstract fun lists(): ShoppingListDao

    abstract fun items(): ListItemDao

    abstract fun visits(): VisitDao

    abstract fun checks(): CheckDao

    abstract fun stores(): StoreDao

    abstract fun graphSnapshots(): GraphSnapshotDao

    abstract fun products(): ProductDao

    abstract fun categories(): CategoryDao

    abstract fun outbox(): OutboxDao

    companion object {
        const val VERSION = 1
        const val FILE_NAME = "parcourses.db"
    }
}
