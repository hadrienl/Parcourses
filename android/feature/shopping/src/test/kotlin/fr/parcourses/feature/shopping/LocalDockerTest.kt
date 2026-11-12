package fr.parcourses.feature.shopping

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Garde du test d'intégration : jamais de `docker exec` sur un démon distant (#54, M6). */
class LocalDockerTest {
    @Test
    fun aLocalSocketIsAccepted() {
        assertTrue(isLocalDockerEndpoint(null, "unix:///var/run/docker.sock"))
        assertTrue(isLocalDockerEndpoint("", "unix:///Users/moi/.docker/run/docker.sock"))
        assertTrue(isLocalDockerEndpoint("unix:///var/run/docker.sock", "unix:///var/run/docker.sock"))
    }

    @Test
    fun aRemoteDaemonIsRefused() {
        assertFalse(isLocalDockerEndpoint("tcp://10.0.0.5:2376", "unix:///var/run/docker.sock"))
        assertFalse(isLocalDockerEndpoint("ssh://moi@serveur", "unix:///var/run/docker.sock"))
        assertFalse(isLocalDockerEndpoint(null, "tcp://docker.example.org:2376"))
        assertFalse(isLocalDockerEndpoint(null, "ssh://moi@serveur"))
    }

    @Test
    fun anUnknownContextIsRefused() {
        assertFalse(isLocalDockerEndpoint(null, null))
        assertFalse(isLocalDockerEndpoint(null, ""))
    }
}
