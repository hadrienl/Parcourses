package fr.parcourses.app

import fr.parcourses.core.network.SupabaseConfig
import fr.parcourses.core.network.session.SessionStorageFiles
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

// La session chiffrée ne doit jamais suivre une sauvegarde : les règles doivent viser les vrais fichiers.
class BackupRulesTest {
    private val datastore = "datastore/${SessionStorageFiles.DATASTORE_FILE}"
    private val keyset = "${SessionStorageFiles.KEYSET_PREFS}.xml"

    private fun excludes(
        file: String,
        section: String? = null,
    ): Set<String> {
        val xml = File("src/main/res/xml/$file").readText()
        val scope = section?.let { xml.substringAfter("<$it>").substringBefore("</$it>") } ?: xml
        return Regex("""<exclude domain="(\w+)" path="([^"]+)"""")
            .findAll(scope)
            .map { "${it.groupValues[1]}:${it.groupValues[2]}" }
            .toSet()
    }

    // Dossier entier : fichiers `.tmp` du DataStore compris.
    private val expected = setOf("file:datastore/", "sharedpref:$keyset")

    @Test
    fun theSessionFilesLiveInTheExcludedDirectory() {
        // Les chemins réels, tels que `DataStoreSecureStateStore.create` les ouvre sous `filesDir`.
        val filesDir = File("files")
        for (file in listOf(SessionStorageFiles.sessionFile(filesDir), SessionStorageFiles.accountFile(filesDir))) {
            val relative = file.relativeTo(filesDir).invariantSeparatorsPath
            assertTrue(relative, relative.startsWith("datastore/"))
        }
        assertEquals(datastore, SessionStorageFiles.sessionFile(filesDir).relativeTo(filesDir).invariantSeparatorsPath)
    }

    @Test
    fun cloudBackupExcludesTheSessionAndItsKeyset() {
        assertEquals(expected, excludes("data_extraction_rules.xml", "cloud-backup"))
    }

    @Test
    fun deviceTransferExcludesTheSessionAndItsKeyset() {
        assertEquals(expected, excludes("data_extraction_rules.xml", "device-transfer"))
    }

    @Test
    fun legacyBackupExcludesTheSessionAndItsKeyset() {
        assertEquals(expected, excludes("backup_rules.xml"))
    }

    @Test
    fun theManifestPointsAtTheRules() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertTrue(manifest.contains("@xml/data_extraction_rules"))
        assertTrue(manifest.contains("@xml/backup_rules"))
        assertTrue(manifest.contains("""android:allowBackup="false""""))
    }

    @Test
    fun debugCleartextHostsMatchTheConfigAccepted() {
        val xml = File("src/debug/res/xml/network_security_config.xml").readText()
        val domains = Regex("""<domain[^>]*>([^<]+)</domain>""").findAll(xml).map { it.groupValues[1].trim() }.toSet()
        val accepted = SupabaseConfig.CLEARTEXT_HOSTS.map { it.removeSurrounding("[", "]") }.toSet()
        assertEquals(accepted, domains)
    }
}
