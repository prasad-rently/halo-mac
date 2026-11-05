package app.halo.tools

enum class NetworkKind(val label: String) { WIFI("Wi-Fi"), CELLULAR("Mobile data"), ETHERNET("Ethernet"), VPN("VPN"), OTHER("Other network"), NONE("No connection") }

/** What the phone reports about its current connection (filled in from ConnectivityManager by the app). */
data class NetworkState(val connected: Boolean, val metered: Boolean, val kind: NetworkKind)

/** Whether, and how loudly, to ask before a test that moves ~30 MB. */
sealed interface SpeedTestGate {
    data class Blocked(val message: String) : SpeedTestGate
    /** Ask first: the connection is metered or cellular, so those megabytes may be billed. */
    data class Confirm(val message: String) : SpeedTestGate
    data object Go : SpeedTestGate

    companion object {
        fun decide(n: NetworkState, plan: SpeedPlan = SpeedPlan()): SpeedTestGate {
            if (!n.connected || n.kind == NetworkKind.NONE) return Blocked("You're offline. Connect to Wi-Fi or mobile data to run a speed test.")
            val mb = plan.estimatedDataBytes / 1_000_000
            return if (n.metered || n.kind == NetworkKind.CELLULAR)
                Confirm("This connection is ${if (n.metered) "metered" else "mobile data"}. The test downloads and uploads about $mb MB, which may count against your data plan.")
            else Go
        }
    }
}
