# Règles R8 propres à Parcourses.

# WorkManager mémorise le nom de la classe du travail en base : il doit survivre à une mise à jour.
-keep class fr.parcourses.core.data.sync.ListSyncWorker { *; }
