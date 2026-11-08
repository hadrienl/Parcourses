package fr.parcourses.core.database

import androidx.room3.ColumnTypeConverter
import kotlin.time.Instant

/** Les dates sont stockées en millisecondes epoch UTC (#10, §3.2), envoyées en ISO 8601 par la couche réseau. */
object InstantConverters {
    @ColumnTypeConverter
    fun toEpochMillis(value: Instant?): Long? = value?.toEpochMilliseconds()

    @ColumnTypeConverter
    fun fromEpochMillis(value: Long?): Instant? = value?.let(Instant::fromEpochMilliseconds)
}
