package fr.parcourses.core.network.session

import io.github.jan.supabase.auth.user.UserSession
import kotlinx.serialization.Serializable
import java.io.IOException

/** Tout ce qui est chiffré sur l'appareil : la session Supabase et le dernier compte connu. */
@Serializable
data class SecureState(
    val session: UserSession? = null,
    /**
     * Dernier compte connu. Pas un secret : il vit dans un fichier à part, **en clair**, pour survivre à la
     * perte de la clé de chiffrement (sinon un nouveau compte anonyme serait adopté sans alerte).
     */
    val lastAccountId: String? = null,
) {
    // Les jetons ne doivent jamais sortir dans un journal.
    override fun toString(): String =
        "SecureState(session=${if (session == null) "null" else "<masquée>"}, lastAccountId=$lastAccountId)"
}

/** Contenu du fichier chiffré : la session seule. */
@Serializable
internal data class SessionHolder(
    val session: UserSession? = null,
) {
    override fun toString(): String = "SessionHolder(<masquée>)"
}

/** Contenu du fichier en clair : le dernier compte connu. */
@Serializable
internal data class AccountMarker(
    val lastAccountId: String? = null,
)

/** Noms des fichiers de session, partagés avec les règles d'exclusion des sauvegardes (`app/src/main/res/xml`). */
object SessionStorageFiles {
    /** `files/datastore/<nom>` : la session, chiffrée. */
    const val DATASTORE_FILE = "parcourses_secure_state.pb"

    /** `files/datastore/<nom>` : le dernier compte connu, en clair. Exclu des sauvegardes comme la session. */
    const val ACCOUNT_FILE = "parcourses_account_marker.json"

    /** `shared_prefs/<nom>.xml` : le jeu de clés Tink, chiffré par la clé maîtresse du Keystore. */
    const val KEYSET_PREFS = "parcourses_tink_keyset"
    const val KEYSET_NAME = "session_keyset"
    const val MASTER_KEY_ALIAS = "parcourses_session_master_key"
    const val MASTER_KEY_URI = "android-keystore://$MASTER_KEY_ALIAS"
}

/** Le Keystore ou le fichier est inaccessible pour l'instant : la session existe peut-être encore. */
class SecureStorageUnavailableException(
    message: String,
    cause: Throwable? = null,
) : IOException(message, cause)

/** Stockage chiffré de [SecureState]. Les écritures sont atomiques et sérialisées. */
interface SecureStateStore {
    /** @throws SecureStorageUnavailableException si le stockage est inaccessible (jamais remplacé par un état vide). */
    suspend fun read(): SecureState

    suspend fun update(transform: (SecureState) -> SecureState)
}
