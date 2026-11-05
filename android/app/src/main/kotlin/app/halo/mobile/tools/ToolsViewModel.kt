package app.halo.mobile.tools

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.halo.tools.HttpSpeedTransport
import app.halo.tools.NetworkKind
import app.halo.tools.NetworkState
import app.halo.tools.SpeedProgress
import app.halo.tools.SpeedResult
import app.halo.tools.SpeedTestEngine
import app.halo.tools.CodeLanguage
import app.halo.tools.CodeTheme
import app.halo.tools.TransformId
import app.halo.tools.TransformResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Everything the Tools hub keeps across a rotation, in a ViewModel — NOT in saved instance state. What the user pastes here
 * can be a password, a token or a config file; saved state is written into the system's Bundle store, a ViewModel only
 * lives in this process's memory. [close] wipes it all when the person leaves Tools.
 */
class ToolsViewModel(app: Application) : AndroidViewModel(app) {
    var isOpen by mutableStateOf(false); private set
    /** Null = the hub list. */
    var toolId by mutableStateOf<String?>(null); private set

    fun openHub() { isOpen = true; toolId = null }
    fun open(id: String) { isOpen = true; toolId = id }
    /** One step back: tool -> hub list -> closed. */
    fun back() { if (toolId != null) toolId = null else close() }
    fun close() { isOpen = false; toolId = null; transform.clear(); beautifier.clear() }

    /** "Transform…" on a clipboard-history item: open the transform tool with that text loaded. */
    fun transformText(text: String) { transform.load(text); open("transform") }

    val transform = TransformState()
    val beautifier = BeautifierState()
    val speed = SpeedTestController()

    override fun onCleared() { speed.cancel(); super.onCleared() }

    // ── state holders ──────────────────────────────────────────────────────────────────────────

    class TransformState {
        var input by mutableStateOf("")
        var selected by mutableStateOf<TransformId?>(null)
        var result by mutableStateOf<TransformResult?>(null)
        var notice by mutableStateOf<String?>(null)
        fun load(text: String) { input = text.take(MAX_INPUT); result = null; selected = null; notice = if (text.length > MAX_INPUT) "Only the first ${MAX_INPUT / 1000} thousand characters were loaded." else null }
        fun clear() { input = ""; selected = null; result = null; notice = null }
        companion object { const val MAX_INPUT = 500_000 }
    }

    class BeautifierState {
        var code by mutableStateOf("")
        var language by mutableStateOf(CodeLanguage.PLAIN_TEXT)
        var theme by mutableStateOf(CodeTheme.default)
        var lineNumbers by mutableStateOf(true)
        var notice by mutableStateOf<String?>(null)
        fun clear() { code = ""; language = CodeLanguage.PLAIN_TEXT; notice = null }
    }

    sealed interface SpeedPhase {
        data object Idle : SpeedPhase
        data class Running(val stage: String, val fraction: Float?, val liveMbps: Double?) : SpeedPhase
        data class Finished(val result: SpeedResult, val atMs: Long) : SpeedPhase
    }

    /** Runs one speed test at a time, off the main thread; [cancel] is honoured within a chunk (~64 KB) or a ping. */
    inner class SpeedTestController {
        var phase by mutableStateOf<SpeedPhase>(SpeedPhase.Idle); private set
        private val cancelFlag = AtomicBoolean(false)
        private var job: Job? = null
        val running get() = phase is SpeedPhase.Running

        fun start() {
            if (running) return
            cancelFlag.set(false); phase = SpeedPhase.Running("Starting", null, null)
            job = viewModelScope.launch(Dispatchers.IO) {
                var lastUi = 0L
                val result = SpeedTestEngine(HttpSpeedTransport()).run(cancelled = cancelFlag::get) { p ->
                    val now = System.nanoTime()
                    when (p) {
                        is SpeedProgress.Pinging -> phase = SpeedPhase.Running("Measuring latency (${p.attempt}/${p.of})", null, null)
                        is SpeedProgress.Downloading -> if (now - lastUi > 120_000_000L) { lastUi = now; phase = SpeedPhase.Running("Downloading", p.fraction.toFloat(), p.mbps) }
                        SpeedProgress.Uploading -> phase = SpeedPhase.Running("Uploading", null, null)
                        is SpeedProgress.Done -> {}
                    }
                }
                phase = if (result.cancelled) SpeedPhase.Idle else SpeedPhase.Finished(result, System.currentTimeMillis())
            }
        }

        fun cancel() { cancelFlag.set(true) }
    }

    /** Current connection facts from ConnectivityManager (ACCESS_NETWORK_STATE is already declared). Read when the screen is shown and when Start is tapped. */
    fun networkState(): NetworkState = NetworkProbe.current(getApplication())
}

internal object NetworkProbe {
    fun current(ctx: Context): NetworkState {
        val cm = ctx.getSystemService(ConnectivityManager::class.java) ?: return NetworkState(false, false, NetworkKind.NONE)
        val caps = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) } ?: return NetworkState(false, false, NetworkKind.NONE)
        val connected = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        val kind = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkKind.CELLULAR
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NetworkKind.WIFI
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> NetworkKind.ETHERNET
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> NetworkKind.VPN
            else -> NetworkKind.OTHER
        }
        return NetworkState(connected, cm.isActiveNetworkMetered, kind)
    }
}
