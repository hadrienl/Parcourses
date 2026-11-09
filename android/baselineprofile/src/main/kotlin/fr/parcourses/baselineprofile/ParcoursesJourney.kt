package fr.parcourses.baselineprofile

import androidx.benchmark.macro.MacrobenchmarkScope
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.StaleObjectException
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import java.util.regex.Pattern

/** Identifiant de l'app mesurée (les variantes de mesure gardent celui de la release). */
const val PACKAGE_NAME = "fr.parcourses.app"

// Délais d'attente d'UI Automator : larges, l'émulateur est lent quand la machine est chargée.
private const val SCREEN_TIMEOUT_MS = 10_000L
private const val SHORT_TIMEOUT_MS = 2_000L

// Délai du tri différé du mode courses (600 ms d'inactivité, #10 §8.2), plus une marge pour l'animation.
private const val RESORT_WAIT_MS = 900L

/** Articles variés (plusieurs rayons) : l'ordre des rayons change vraiment la liste. */
val SAMPLE_ITEMS =
    listOf(
        "Lait",
        "Pain",
        "Pommes",
        "Tomates",
        "Pâtes",
        "Riz",
        "Yaourts",
        "Beurre",
        "Café",
        "Jambon",
        "Fromage",
        "Œufs",
        "Bananes",
        "Salade",
        "Eau",
        "Jus d'orange",
        "Chocolat",
        "Farine",
        "Sucre",
        "Lessive",
    )

/**
 * Recherche de magasin facultative, passée par
 * `-Pandroid.testInstrumentationRunnerArguments.parcourses.storeQuery=<nom>`. Sans elle, le parcours continue sans
 * magasin (ordre générique) et ne demande aucun réseau. Avec elle, il faut l'APK construit avec
 * `-Pparcourses.env=local` et le Supabase local démarré.
 */
val storeQuery: String? get() = InstrumentationRegistry.getArguments().getString("parcourses.storeQuery")

/**
 * Les permissions demandées en cours de route (notifications de la Live Update) sont accordées d'avance : une
 * fenêtre système au milieu d'une mesure la fausserait. La position n'est pas accordée : le choix du magasin
 * passe par la recherche ou « Continuer sans magasin ».
 */
fun MacrobenchmarkScope.grantNotifications() {
    device.executeShellCommand("pm grant $packageName android.permission.POST_NOTIFICATIONS")
}

private fun MacrobenchmarkScope.waitFor(
    selector: BySelector,
    timeout: Long = SCREEN_TIMEOUT_MS,
): UiObject2 =
    checkNotNull(device.wait(Until.findObject(selector), timeout)) {
        "Introuvable à l'écran : $selector"
    }

/** Une visite restée ouverte rouvre le mode courses au lancement : on la termine pour repartir des listes. */
fun MacrobenchmarkScope.finishOpenVisitIfAny() {
    if (device.wait(Until.hasObject(By.res("shoppingItems")), SHORT_TIMEOUT_MS)) finishShopping()
}

/** Listes → nouvelle liste → saisie rapide de [items]. L'app ouvre la liste créée. */
fun MacrobenchmarkScope.createList(
    name: String,
    items: List<String> = SAMPLE_ITEMS,
) {
    waitFor(By.res("newList")).click()
    // Le dialogue est une fenêtre à part : pas d'identifiant de ressource, on passe par la classe et le libellé.
    waitFor(By.clazz(EDIT_TEXT)).text = name
    waitFor(By.text("Créer").enabled(true)).click()
    val entry = waitFor(By.res("quickEntry"))
    for (item in items) {
        entry.text = item
        waitFor(By.res("add").enabled(true)).click()
        device.wait(Until.findObject(By.res("add").enabled(false)), SHORT_TIMEOUT_MS)
    }
    device.waitForIdle()
}

/** Liste ouverte → choix du magasin → mode courses. */
fun MacrobenchmarkScope.startShopping() {
    // Le clavier de la saisie rapide peut masquer le bouton : on ne le ferme que s'il le faut.
    if (!device.wait(Until.hasObject(By.res("startShopping")), SHORT_TIMEOUT_MS)) device.pressBack()
    waitFor(By.res("startShopping")).click()
    val query = storeQuery
    if (query.isNullOrBlank()) {
        // Dernier élément de la liste : hors écran sur un petit écran ou en grand texte, on fait défiler.
        val withoutStore = By.res("storepicker.withoutStore")
        val target =
            device.wait(Until.findObject(withoutStore), SHORT_TIMEOUT_MS)
                ?: device.findObject(By.scrollable(true))?.scrollUntil(Direction.DOWN, Until.findObject(withoutStore))
        checkNotNull(target) { "Introuvable à l'écran : $withoutStore" }.click()
    } else {
        // La recherche part d'elle-même pendant la saisie.
        waitFor(By.res("storepicker.search")).text = query
        clickStoreMatching(query)
    }
    waitFor(By.res("shoppingItems"))
}

/**
 * Touche la première ligne de résultat dont le nom ou l'adresse contient [query] (le champ de saisie le contient
 * aussi). Les résultats arrivent pendant la lecture : un nœud périmé est relu.
 */
private fun MacrobenchmarkScope.clickStoreMatching(query: String) {
    val pattern = By.text(Pattern.compile("(?i).*${Pattern.quote(query)}.*"))
    val deadline = System.currentTimeMillis() + SCREEN_TIMEOUT_MS
    while (System.currentTimeMillis() < deadline) {
        try {
            val store = device.findObjects(pattern).firstOrNull { it.className != EDIT_TEXT }
            if (store != null) {
                store.click()
                return
            }
        } catch (_: StaleObjectException) {
            // Relu au tour suivant.
        }
        device.waitForIdle()
    }
    error("Aucun magasin trouvé pour « $query »")
}

/**
 * Coche [count] articles, un par un, en laissant le tri différé réordonner la liste entre deux coches. Le groupe
 * « Dans le panier » est replié : la première case visible est l'article suivant.
 */
fun MacrobenchmarkScope.checkItems(count: Int) {
    repeat(count) {
        // Relue à chaque coche : le réordonnancement recompose les lignes et périme les nœuds déjà lus.
        val clicked =
            (1..MAX_ATTEMPTS).any {
                try {
                    val next = waitFor(By.res("shoppingItems")).findObject(By.clazz("android.widget.CheckBox"))
                    next?.click()
                    next != null
                } catch (_: StaleObjectException) {
                    device.waitForIdle()
                    false
                }
            }
        // Plus aucune case : la mesure ou le profil perdraient les coches sans le dire.
        check(clicked) { "Aucun article à cocher dans le mode courses" }
        Thread.sleep(RESORT_WAIT_MS)
        device.waitForIdle()
    }
}

/** Fait défiler le mode courses jusqu'en bas puis remonte. */
fun MacrobenchmarkScope.scrollShopping() {
    for (direction in listOf(Direction.DOWN, Direction.UP)) {
        val list = waitFor(By.res("shoppingItems"))
        // Marge pour ne pas saisir la barre système ni le dock.
        list.setGestureMarginPercentage(GESTURE_MARGIN)
        list.fling(direction)
        device.waitForIdle()
    }
}

/** « Terminer » → retirer ce qui reste → résumé → fermer, puis retour à l'écran des listes. */
fun MacrobenchmarkScope.finishShopping() {
    waitFor(By.res("finish")).click()
    // La feuille « garder ou retirer » n'apparaît que s'il reste des articles. Fenêtre à part : pas d'identifiant.
    device.wait(Until.findObject(By.text("Les retirer de la liste")), SHORT_TIMEOUT_MS)?.click()
    waitFor(By.res("closeSummary")).click()
    // Le résumé rend la main à la liste (ou aux listes, après une reprise au lancement).
    repeat(MAX_BACKS) {
        if (device.wait(Until.hasObject(By.res("newList")), SHORT_TIMEOUT_MS)) return
        device.pressBack()
    }
    waitFor(By.res("newList"))
}

private const val MAX_BACKS = 3
private const val EDIT_TEXT = "android.widget.EditText"
private const val MAX_ATTEMPTS = 3
private const val GESTURE_MARGIN = 0.2f
