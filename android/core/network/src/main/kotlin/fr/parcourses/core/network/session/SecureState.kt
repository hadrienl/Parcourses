package fr.parcourses.core.network.session

import io.github.jan.supabase.auth.user.UserSession
import kotlinx.serialization.Serializable
import java.io.IOException

/** Tout ce qui est chiffré sur l'appareil : la session Supabase et le dernier compte connu. */
@Serializable
data class SecureState(
    val session: UserSession? = null,
    /** Dernier compte connu, à côté de la session : détecte un changement de compte. */
    val lastAccountId: String? = null,
)

/** Noms des fichiers de session, partagés avec les règles d'exclusion des sauvegardes (`app/src/main/res/xml`). */
object SessionStorageFiles {
    /** `files/datastore/<nom>`. */
    const val DATASTORE_FILE = "parcourses_secure_state.pb"

    /** `shared_prefs/<nom>.xml` : le jeu de clés Tink, chiffré par la clé maîtresse du Keystore. */
    const val KEYSET_PREFS = "parcourses_tink_keyset"
    const val KEYSET_NAME = "session_keyset"
    const val MASTER_KEY_URI = "android-keystore://parcourses_session_master_key"
}

/** Le Keystore ou le fichier est inaccessible pour l'instant : la session existe peut-être encore. */
class SecureStorageUnavailableException(message: String, cause: Throwable? = null) : IOException(message, cause)

/** Stockage chiffré de [SecureState]. Les écritures sont atomiques et sérialisées. */
interface SecureStateStore {
    /** @throws SecureStorageUnavailableException si le stockage est inaccessible (jamais remplacé par un état vide). */
    suspend fun read(): SecureState

    suspend fun update(transform: (SecureState) -> SecureState)
}
