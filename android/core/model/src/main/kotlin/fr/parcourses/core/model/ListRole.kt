package fr.parcourses.core.model

/**
 * Rôle sur une liste (#87 §1) : même nom et mêmes cas qu'iOS (`ListRole`). [wireName] est la valeur du serveur
 * (`list_members.role`, `list_sharing`) et des vecteurs `shared/test-vectors/sharing/`.
 */
enum class ListRole(
    val wireName: String,
) {
    /** Crée la liste, la partage, gère les membres, la renomme et la supprime. */
    Owner("owner"),

    /** « Peut modifier » : ajoute, modifie et coche les articles. */
    Editor("editor"),

    /** « Lecture seule » : voit la liste, sans la modifier ni faire les courses (Q5). */
    Viewer("viewer"),
    ;

    companion object {
        /** `null` pour une valeur inconnue de cette version de l'app. */
        fun fromWire(value: String?): ListRole? = entries.firstOrNull { it.wireName == value }
    }
}
