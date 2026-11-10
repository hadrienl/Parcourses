# Règles R8 de :core:network, appliquées à l'app qui l'embarque (A12).

# `KeystoreAeadSource.isCorruptionProof` reconnaît une session corrompue au nom simple de l'exception
# (`InvalidProtocolBufferException`, dans le protobuf ombré de Tink). Renommée par R8, elle ne serait plus reconnue
# et une session illisible ne serait jamais recréée. `AEADBadTagException` vient de la plateforme : jamais renommée.
-keepnames class **.InvalidProtocolBufferException
