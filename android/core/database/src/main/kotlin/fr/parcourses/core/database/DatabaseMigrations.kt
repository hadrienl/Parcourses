package fr.parcourses.core.database

import androidx.room3.migration.Migration
import androidx.sqlite.SQLiteConnection
import androidx.sqlite.execSQL

/** Migrations de la base, vérifiées par `MigrationTest` sur les schémas exportés (`schemas/`). */
object DatabaseMigrations {
    /**
     * Version 2 (#87, lot 87.5) : `lists.ownerId`, `list_items.isOnServer` et `list_items.updatedBy`,
     * `outbox.changedFields`. Un article `SYNCED` est déjà sur le serveur ; les autres l'ignorent : leur entrée en
     * file, sans `changedFields`, garde l'ancien envoi (tous les champs, puis insertion si aucune ligne).
     */
    val MIGRATION_1_2: Migration =
        object : Migration(1, 2) {
            override suspend fun migrate(connection: SQLiteConnection) {
                connection.execSQL("ALTER TABLE `lists` ADD COLUMN `ownerId` TEXT")
                connection.execSQL("ALTER TABLE `list_items` ADD COLUMN `isOnServer` INTEGER NOT NULL DEFAULT 0")
                connection.execSQL("ALTER TABLE `list_items` ADD COLUMN `updatedBy` TEXT")
                connection.execSQL("UPDATE `list_items` SET `isOnServer` = 1 WHERE `syncState` = 'SYNCED'")
                connection.execSQL("ALTER TABLE `outbox` ADD COLUMN `changedFields` TEXT")
            }
        }

    /**
     * Version 3 (#87, lot 87.6) : `lists.role` (une liste déjà sur l'appareil est à soi : aucune liste d'un autre
     * n'a pu arriver avant le partage) et la table `list_participants`, remplie à la descente suivante.
     */
    val MIGRATION_2_3: Migration =
        object : Migration(2, 3) {
            override suspend fun migrate(connection: SQLiteConnection) {
                connection.execSQL("ALTER TABLE `lists` ADD COLUMN `role` TEXT NOT NULL DEFAULT 'Owner'")
                connection.execSQL(
                    "CREATE TABLE IF NOT EXISTS `list_participants` (`listId` TEXT NOT NULL, `userId` TEXT NOT NULL, " +
                        "`displayName` TEXT, `role` TEXT NOT NULL, `isMe` INTEGER NOT NULL, `joinedAt` INTEGER, " +
                        "PRIMARY KEY(`listId`, `userId`))",
                )
                connection.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_list_participants_userId` ON `list_participants` (`userId`)",
                )
            }
        }

    val ALL: Array<Migration> = arrayOf(MIGRATION_1_2, MIGRATION_2_3)
}
