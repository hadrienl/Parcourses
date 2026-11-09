package fr.parcourses.baselineprofile

import androidx.benchmark.macro.BaselineProfileMode
import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Mode courses : coches successives (chacune relance le tri et anime le réordonnancement), puis défilement.
 * Mesure le temps de rendu des images (#10 §11, « tri »), sans profil puis avec le Baseline Profile.
 */
@RunWith(AndroidJUnit4::class)
class ShoppingBenchmark {
    @get:Rule
    val rule = MacrobenchmarkRule()

    @Test
    fun checkAndScrollWithoutProfile() = checkAndScroll(CompilationMode.None())

    @Test
    fun checkAndScrollWithBaselineProfile() = checkAndScroll(CompilationMode.Partial(BaselineProfileMode.Require))

    private fun checkAndScroll(mode: CompilationMode) {
        var round = 0
        rule.measureRepeated(
            packageName = PACKAGE_NAME,
            metrics = listOf(FrameTimingMetric()),
            compilationMode = mode,
            iterations = ITERATIONS,
            setupBlock = {
                grantNotifications()
                pressHome()
                startActivityAndWait()
                finishOpenVisitIfAny()
                createList("Mesure ${round++}")
                startShopping()
            },
        ) {
            checkItems(CHECKED)
            scrollShopping()
        }
    }

    private companion object {
        const val ITERATIONS = 5
        const val CHECKED = 8
    }
}
