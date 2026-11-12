package fr.parcourses.core.network.session

import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import java.io.File
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
    /** Dossier des deux fichiers, sous `files/`, exclu en entier des sauvegardes. */
    const val DIRECTORY = "datastore"

    /** `files/datastore/<nom>` : la session, chiffrée. */
    const val DATASTORE_FILE = "parcourses_secure_state.pb"

    /** `files/datastore/<nom>` : le dernier compte connu, en clair. Exclu des sauvegardes comme la session. */
    const val ACCOUNT_FILE = "parcourses_account_marker.json"

    /** `shared_prefs/<nom>.xml` : le jeu de clés Tink, chiffré par la clé maîtresse du Keystore. */
    const val KEYSET_PREFS = "parcourses_tink_keyset"
    const val KEYSET_NAME = "session_keyset"
    const val MASTER_KEY_ALIAS = "parcourses_session_master_key"
    const val MASTER_KEY_URI = "android-keystore://$MASTER_KEY_ALIAS"

    /** Le fichier de la session, sous [filesDir] (`Context.filesDir`). */
    fun sessionFile(filesDir: File): File = File(File(filesDir, DIRECTORY), DATASTORE_FILE)

    /** Le fichier du dernier compte connu, sous [filesDir] (`Context.filesDir`). */
    fun accountFile(filesDir: File): File = File(File(filesDir, DIRECTORY), ACCOUNT_FILE)
}

/** Le Keystore ou le fichier est inaccessible pour l'instant : la session existe peut-être encore. */
class SecureStorageUnavailableException(
    message: String,
    cause: Throwable? = null,
) : IOException(message, cause)

/** Stockage chiffré de [SecureState]. Chaque [update] (lecture, transformation, écriture) est atomique et exclusif. */
interface SecureStateStore {
    /** @throws SecureStorageUnavailableException si le stockage est inaccessible (jamais remplacé par un état vide). */
    suspend fun read(): SecureState

    /**
     * Lit, transforme et écrit sous un verrou **non réentrant** : [transform] ne doit jamais rappeler ce store
     * (ni [read], ni [update], ni le `SessionManager` qui s'appuie dessus), sous peine de blocage définitif.
     */
    suspend fun update(transform: (SecureState) -> SecureState)

    /**
     * Le stockage chiffré reste illisible : plusieurs échecs de suite, sans réussite entre eux. Seule la personne
     * peut alors trancher, par [resetSession].
     */
    val isStuck: StateFlow<Boolean> get() = NeverStuck

    /**
     * Vérifie que la session pourra être écrite, clé comprise, **avant** de créer un compte : sinon le compte
     * existerait sur le serveur sans que l'appareil en garde la session.
     * @throws SecureStorageUnavailableException si l'écriture échouerait.
     */
    suspend fun checkWritable() {
        read()
    }

    /**
     * Repart d'une session vide quand la clé reste inaccessible : le matériel de clé est détruit puis recréé, la
     * session effacée. Le dernier compte connu est **conservé** : la synchronisation réidentifiera les données
     * locales pour le prochain compte, comme après une clé perdue.
     * @return `false` si la clé s'ouvre de nouveau : rien n'est détruit, la session reste.
     * @throws SecureStorageUnavailableException si le Keystore refuse l'effacement.
     */
    suspend fun resetSession(): Boolean {
        update { it.copy(session = null) }
        return true
    }
}

private val NeverStuck: StateFlow<Boolean> = MutableStateFlow(false).asStateFlow()
