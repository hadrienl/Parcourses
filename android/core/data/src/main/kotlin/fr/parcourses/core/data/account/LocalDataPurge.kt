package fr.parcourses.core.data.account

import androidx.room3.useWriterConnection
import fr.parcourses.core.data.attestation.AttestationStore
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
 * - les curseurs de synchronisation (`sync_cursors`, compte compris) ;
 * - le drapeau `account.kind` (#87) : l'appareil repart avec un compte anonyme ; et `account.switch` ;
 * - l'état de l'attestation d'appareil (#137).
 *
 * La session et le dernier compte connu sont vidés ensuite par `RemoteGateway.signOutLocally` ; la Live Update et
 * ses préférences, par l'app avant la suppression. Rejouable sans dommage : une base déjà vide le reste.
 */
class LocalDataPurge(
    private val db: ParcoursesDatabase,
    private val cursors: SyncCursors,
    private val seed: () -> CategorySeed = CategorySeed::bundled,
    private val accountKind: AccountKindFlag? = null,
    private val switchFlag: AccountSwitchFlag? = null,
    private val attestation: AttestationStore? = null,
) {
    /** Une panne lève une [PurgeStepException] qui porte son étape : base, catégories, puis préférences (#129). */
    suspend fun run() {
        purgeStep(PurgeStep.Store) {
            // Hors de toute transaction : dans une transaction, Room 3 saute le `VACUUM`.
            db.clearAllTables()
            db.useWriterConnection { connection -> connection.usePrepared(WAL_TRUNCATE) { it.step() } }
        }
        purgeStep(PurgeStep.Categories) { db.categories().seedIfNeeded(seed()) }
        purgeStep(PurgeStep.Preferences) {
            cursors.clear()
            accountKind?.clear()
            // Plus rien à reprendre : un changement de compte en attente n'a plus d'objet.
            switchFlag?.clear()
            attestation?.clear()
        }
    }

    private companion object {
        const val WAL_TRUNCATE = "PRAGMA wal_checkpoint(TRUNCATE)"
    }
}
