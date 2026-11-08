package fr.parcourses.core.data.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities

/**
 * État du réseau. Optimiste tant que le premier état n'est pas connu. [onReturn] est appelé à chaque retour du
 * réseau, jamais au démarrage.
 */
class NetworkMonitor(
    context: Context,
    private val onReturn: () -> Unit,
) {
    private val connectivity = context.applicationContext.getSystemService(ConnectivityManager::class.java)

    @Volatile
    private var online = true

    val isOnline: Boolean get() = online

    fun start() {
        val manager = connectivity ?: return
        online = hasInternet(manager, manager.activeNetwork)
        manager.registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    val wasOnline = online
                    online = true
                    if (!wasOnline) onReturn()
                }

                override fun onLost(network: Network) {
                    online = false
                }
            },
        )
    }

    private fun hasInternet(
        manager: ConnectivityManager,
        network: Network?,
    ): Boolean =
        network?.let { manager.getNetworkCapabilities(it)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) }
            ?: false
}
