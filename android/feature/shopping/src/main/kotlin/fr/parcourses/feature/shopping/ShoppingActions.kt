package fr.parcourses.feature.shopping

/** Ce que l'écran peut demander. Une seule valeur à passer, stable d'une recomposition à l'autre. */
class ShoppingActions(
    val onBack: () -> Unit = {},
    val onToggle: (ShoppingRow) -> Unit = {},
    val onNotFound: (ShoppingRow) -> Unit = {},
    val onRestore: (ShoppingRow) -> Unit = {},
    val onSubmit: () -> Unit = {},
    val onUndo: () -> Unit = {},
    val onFinish: (keepRemaining: Boolean) -> Unit = {},
    val onDismissError: () -> Unit = {},
    val onScrolling: (Boolean) -> Unit = {},
    val onEditing: (Boolean) -> Unit = {},
    val onAnnouncementShown: (Int) -> Unit = {},
    val onClose: () -> Unit = {},
    /** Retour haptique d'une coche (appelé avant [onToggle], seulement pour cocher). */
    val onCheckFeedback: () -> Unit = {},
)
