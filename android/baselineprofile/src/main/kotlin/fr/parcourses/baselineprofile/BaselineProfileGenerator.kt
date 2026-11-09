package fr.parcourses.baselineprofile

import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Génère le Baseline Profile de l'app (A12) : lancement, puis le parcours principal liste → mode courses → coches →
 * fin. Le profil de démarrage (rangement du DEX par R8) ne reprend que le lancement.
 *
 * Commande de référence, appareil API 33+ branché et Supabase local démarré (une release configurée se connecte et
 * synchronise dès le lancement : le profil doit couvrir ce code) :
 * ```
 * ./gradlew :app:generateBaselineProfile -Pparcourses.env=local -Pparcourses.supabase.local.key=<PUBLISHABLE_KEY> \
 *   -Pandroid.testInstrumentationRunnerArguments.parcourses.storeQuery=Biocoop
 * ```
 * Sans ces options, le parcours reste hors ligne et continue sans magasin.
 */
@RunWith(AndroidJUnit4::class)
class BaselineProfileGenerator {
    @get:Rule
    val rule = BaselineProfileRule()

    @Test
    fun startup() =
        rule.collect(packageName = PACKAGE_NAME, includeInStartupProfile = true) {
            pressHome()
            startActivityAndWait()
        }

    @Test
    fun shoppingJourney() {
        var round = 0
        rule.collect(packageName = PACKAGE_NAME, maxIterations = MAX_ITERATIONS) {
            grantNotifications()
            pressHome()
            startActivityAndWait()
            finishOpenVisitIfAny()
            createList("Profil ${round++}")
            startShopping()
            checkItems(CHECKED)
            scrollShopping()
            finishShopping()
        }
    }

    private companion object {
        const val CHECKED = 6

        // Le profil se stabilise en quelques passages ; 8 au plus garde la génération sous 10 min sur émulateur.
        const val MAX_ITERATIONS = 8
    }
}
