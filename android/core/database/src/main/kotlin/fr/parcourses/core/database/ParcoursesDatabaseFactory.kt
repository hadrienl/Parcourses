package fr.parcourses.core.database

import android.content.Context
import androidx.room3.Room
import androidx.sqlite.SQLiteDriver
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import kotlinx.coroutines.CoroutineDispatcher

/** Construction de la base. Les dispatchers et le pilote sont injectés pour les tests. */
object ParcoursesDatabaseFactory {
    /**
     * Base de l'app, dans le stockage interne. Pilote SQLite embarqué par défaut : la même version de SQLite sur
     * tous les appareils (le SQLite système de l'API 26 n'a ni `UPSERT` ni fonctions récentes).
     * Pas de `fallbackToDestructiveMigration` : la base contient des écritures pas encore envoyées.
     */
    fun create(
        context: Context,
        queryDispatcher: CoroutineDispatcher,
        driver: SQLiteDriver = BundledSQLiteDriver(),
        name: String = ParcoursesDatabase.FILE_NAME,
    ): ParcoursesDatabase =
        Room
            .databaseBuilder(context.applicationContext, ParcoursesDatabase::class.java, name)
            .setDriver(driver)
            .setQueryCoroutineContext(queryDispatcher)
            .build()

    /** Base en mémoire, pour les tests. */
    fun createInMemory(
        context: Context,
        queryDispatcher: CoroutineDispatcher,
        driver: SQLiteDriver,
    ): ParcoursesDatabase =
        Room
            .inMemoryDatabaseBuilder(context.applicationContext, ParcoursesDatabase::class.java)
            .setDriver(driver)
            .setQueryCoroutineContext(queryDispatcher)
            .build()
}
