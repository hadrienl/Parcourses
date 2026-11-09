# Règles R8 de :core:data, appliquées à l'app qui l'embarque (A12).

# WorkManager enregistre en base le nom de la classe de chaque travail et le relit après une mise à jour.
# Renommé autrement d'une version à l'autre, un travail en attente ne serait plus reconnu par `SyncWorkerFactory`.
-keepnames class * extends androidx.work.ListenableWorker
