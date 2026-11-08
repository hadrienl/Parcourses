package fr.parcourses.core.database.entity

/** État d'envoi d'une entité synchronisée (#9 §4.1). Mêmes valeurs que `SyncState` côté iOS. */
enum class SyncState {
    PENDING,
    SYNCED,
    FAILED,
}

/** Nature d'une entrée de la file d'envoi (#9 §5.1). `raw` reprend les valeurs iOS (`upsertList`…). */
enum class OutboxKind(
    val raw: String,
) {
    UpsertList("upsertList"),
    DeleteList("deleteList"),
    UpsertItem("upsertItem"),
    DeleteItem("deleteItem"),
    CreateVisit("createVisit"),
    InsertChecks("insertChecks"),
    CloseVisit("closeVisit"),
    ;

    companion object {
        /** `null` si le type stocké est inconnu de cette version de l'app. */
        fun fromRaw(raw: String): OutboxKind? = entries.firstOrNull { it.raw == raw }
    }
}
