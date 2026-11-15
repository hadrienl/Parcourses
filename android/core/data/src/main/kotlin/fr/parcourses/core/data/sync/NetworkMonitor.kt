package fr.parcourses.core.data.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * État du réseau. Optimiste tant que le premier état n'est pas connu. [onReturn] est appelé à chaque retour du
 * réseau, jamais au démarrage.
 */
class NetworkMonitor(
    context: Context,
    private val onReturn: () -> Unit,
) {
    private val connectivity = context.applicationContext.getSystemService(ConnectivityManager::class.java)

    private val state = MutableStateFlow(true)

    private var online: Boolean
        get() = state.value
        set(value) {
            state.value = value
        }

    val isOnline: Boolean get() = online

    /** Le même état, observable : bandeau « Hors ligne » d'une liste partagée (#87, lot 87.6). */
    val onlineState: StateFlow<Boolean> = state.asStateFlow()

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
