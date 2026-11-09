# Règles R8 propres à l'app (A12). Les modules déclarent les leurs dans leur `consumer-rules.pro` :
# - :core:data    : noms des workers (WorkManager les enregistre en base) ;
# - :core:network : nom de l'exception de protobuf que la détection de session corrompue reconnaît.
#
# Aucune autre règle n'est nécessaire (vérifié sur l'APK minifié, parcours complet contre le Supabase local) :
# - Room 3, WorkManager, kotlinx.serialization, Ktor, Tink et les coroutines livrent leurs propres règles ;
# - les sérialiseurs sont résolus à la compilation (`serializer()`), et les routes de navigation sont déclarées une à
#   une dans `routeConfiguration` : aucune recherche de classe par réflexion ;
# - le receiver de la Live Update est gardé par le manifeste.
# `scripts/check-r8-mapping.sh` vérifie après `assembleRelease` que les noms gardés le restent.
