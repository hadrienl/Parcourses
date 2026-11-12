package fr.parcourses.feature.shopping

/**
 * Le démon Docker visé est celui de cette machine (#54, M6) : `docker port` ne prouve pas qu'un conteneur du même
 * nom n'est pas ailleurs. [dockerHost] : la variable `DOCKER_HOST` ; [contextEndpoint] : l'hôte du contexte courant
 * (`docker context inspect --format '{{.Endpoints.docker.Host}}'`). Seul un socket local est accepté.
 */
internal fun isLocalDockerEndpoint(
    dockerHost: String?,
    contextEndpoint: String?,
): Boolean {
    fun isLocalSocket(endpoint: String) = endpoint.startsWith("unix://") || endpoint.startsWith("npipe://")
    if (!dockerHost.isNullOrBlank() && !isLocalSocket(dockerHost.trim())) return false
    return contextEndpoint != null && isLocalSocket(contextEndpoint.trim())
}
