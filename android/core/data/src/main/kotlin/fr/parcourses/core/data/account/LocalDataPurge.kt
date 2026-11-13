package fr.parcourses.core.data.account

import androidx.room3.useWriterConnection
import fr.parcourses.core.data.sync.SyncCursors
import fr.parcourses.core.database.CategorySeed
import fr.parcourses.core.database.ParcoursesDatabase

/**
 * Efface ce que l'appareil garde du compte (#68 §5.4), sans toucher au serveur ni à la session :
 * - toute la base (`lists`, `list_items`, `visits`, `checks`, `outbox`, `stores`, `graph_snapshots`, `products`,
 *   `categories`, `category_seed_state`) par `clearAllTables`, qui vide tout dans **une seule transaction** puis
 *   compacte le fichier (`VACUUM`), puis vide le journal WAL (`wal_checkpoint(TRUNCATE)`) : les lignes effacées ne
 *   restent ni dans les pages libres ni dans le journal ;
 * - puis le nouvel amorçage des catégories (le voile « Suppression… » cache l'instant sans référentiel) ;
 * - les curseurs de synchronisation (`sync_cursors`, compte compris).
 *
 * La session et le dernier compte connu sont vidés ensuite par `RemoteGateway.signOutLocally` ; la Live Update et
 * ses préférences, par l'app avant la suppression. Rejouable sans dommage : une base déjà vide le reste.
 */
class LocalDataPurge(
    private val db: ParcoursesDatabase,
    private val cursors: SyncCursors,
    private val seed: () -> CategorySeed = CategorySeed::bundled,
) {
    suspend fun run() {
        // Hors de toute transaction : dans une transaction, Room 3 saute le `VACUUM`.
        db.clearAllTables()
        db.useWriterConnection { connection -> connection.usePrepared(WAL_TRUNCATE) { it.step() } }
        db.categories().seedIfNeeded(seed())
        cursors.clear()
    }

    private companion object {
        const val WAL_TRUNCATE = "PRAGMA wal_checkpoint(TRUNCATE)"
    }
}
