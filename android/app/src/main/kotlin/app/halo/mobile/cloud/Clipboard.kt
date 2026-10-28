package app.halo.mobile.cloud

import android.accessibilityservice.AccessibilityService
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.widget.Toast
import app.halo.cloud.ClipboardSyncEngine
import app.halo.cloud.RemoteClip
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.util.concurrent.Executors

@Serializable
data class ClipItem(val id: String, val text: String, val kind: String, val from: String, val atMs: Long, val received: Boolean)

/** The phone-side clipboard history (D9: remote copies land HERE — never in the live clipboard). Capped like the cloud. */
class ClipboardHistory(ctx: Context) {
    private val file = File(ctx.filesDir, "clipboard-history.json")
    private val json = Json { ignoreUnknownKeys = true }
    private val ser = ListSerializer(ClipItem.serializer())
    private val _items = MutableStateFlow(load())
    val items: StateFlow<List<ClipItem>> = _items

    private fun load(): List<ClipItem> = try { if (file.exists()) json.decodeFromString(ser, file.readText()) else emptyList() } catch (e: Exception) { emptyList() }

    @Synchronized fun add(item: ClipItem) {
        if (_items.value.any { it.id == item.id }) return
        val next = (listOf(item) + _items.value).sortedByDescending { it.atMs }.take(ClipboardSyncEngine.CAP)
        _items.value = next; persist(next)
    }

    @Synchronized fun clear() { _items.value = emptyList(); file.delete() }
    private fun persist(l: List<ClipItem>) { runCatching { file.writeText(json.encodeToString(ser, l)) } }

    companion object {
        @Volatile private var instance: ClipboardHistory? = null
        fun get(ctx: Context): ClipboardHistory = instance ?: synchronized(this) { instance ?: ClipboardHistory(ctx.applicationContext).also { instance = it } }
    }
}

/**
 * Process-wide clipboard sync (F-045). One engine and one stream for the whole process, whichever of the
 * accessibility service or the app started it — two live streams would deliver every remote clip twice.
 */
object ClipboardController {
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "halo-clip").apply { isDaemon = true } }
    @Volatile private var engine: ClipboardSyncEngine? = null     // read off-lock by publishText/copyToClipboard
    private var stream: AutoCloseable? = null
    private var listener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private val _status = MutableStateFlow("")
    val status: StateFlow<String> = _status

    /** Start (or restart) publishing + receiving, if the user has it on and the phone is paired. */
    @Synchronized fun start(ctx: Context) {
        val app = ctx.applicationContext
        val prefs = CloudPrefs(app)
        if (!prefs.clipboardEnabled) { stop(); return }
        io.execute {
            try {
                val session = CloudRuntime.session(app) ?: run { _status.value = "Not paired."; return@execute }
                synchronized(this) {
                    // Sign-in above can take seconds. If the user switched sync off (stop()) or disconnected in the
                    // meantime, opening the stream now would leave a live subscription nobody can turn off.
                    if (!CloudPrefs(app).clipboardEnabled) return@execute
                    stream?.close()
                    val e = ClipboardSyncEngine(session.rtdb, session.crypto, session.deviceId, session.deviceName, { prefs.clipboardFilter })
                    engine = e
                    val history = ClipboardHistory.get(app)
                    stream = e.observe { r: RemoteClip -> history.add(ClipItem(r.itemId, r.text, r.kind, r.deviceName, r.createdAtMs, received = true)) }
                    _status.value = "Syncing"
                }
            } catch (e: Exception) { _status.value = e.message ?: "Couldn't connect." }
        }
        listen(app)
    }

    @Synchronized fun stop() { stream?.close(); stream = null; engine = null; _status.value = "" }

    private fun listen(app: Context) {
        if (listener != null) return
        val cm = app.getSystemService(ClipboardManager::class.java) ?: return
        val l = ClipboardManager.OnPrimaryClipChangedListener { onLocalCopy(app) }
        cm.addPrimaryClipChangedListener(l); listener = l
    }

    /** A copy happened. Read it (only possible when Android lets this process) and publish. */
    fun onLocalCopy(ctx: Context) {
        val app = ctx.applicationContext
        if (!CloudPrefs(app).clipboardEnabled) return
        val text = readClipboard(app) ?: return
        publishText(app, text)
    }

    /** Null when the clipboard is empty or Android won't let a background process read it (10+). */
    fun readClipboard(ctx: Context): String? = try {
        ctx.getSystemService(ClipboardManager::class.java)?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString()?.takeIf { it.isNotBlank() }
    } catch (e: SecurityException) { null }

    /** Upload `text` (off the calling thread). [done] reports a human-readable outcome. */
    fun publishText(ctx: Context, text: String, done: ((String) -> Unit)? = null) {
        val app = ctx.applicationContext
        io.execute {
            val result = try {
                val e = engine ?: run {
                    val session = CloudRuntime.session(app) ?: return@execute run { done?.invoke("This phone isn't paired yet.") ; Unit }
                    val prefs = CloudPrefs(app)
                    ClipboardSyncEngine(session.rtdb, session.crypto, session.deviceId, session.deviceName, { prefs.clipboardFilter }).also { engine = it }
                }
                when (val r = e.publish(text)) {
                    ClipboardSyncEngine.Publish.Sent -> { ClipboardHistory.get(app).add(ClipItem(java.util.UUID.randomUUID().toString(), text, ClipboardSyncEngine.kindOf(text), "This phone", System.currentTimeMillis(), received = false)); "Sent to your Mac." }
                    ClipboardSyncEngine.Publish.Duplicate -> "Already sent."
                    ClipboardSyncEngine.Publish.Empty -> "Nothing to send."
                    ClipboardSyncEngine.Publish.Excluded -> "Kept off the cloud — it looks like a secret (the filter is on)."
                    is ClipboardSyncEngine.Publish.Failed -> "Couldn't send: ${r.why}"
                }
            } catch (e: Exception) { "Couldn't send: ${e.message}" }
            _status.value = result
            done?.invoke(result)
        }
    }

    /** Put a received clip on the live clipboard — only ever because the user tapped Copy (D9). */
    fun copyToClipboard(ctx: Context, item: ClipItem) {
        engine?.suppressEcho(item.text)               // so our own listener doesn't publish it straight back
        ctx.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("Halo", item.text))
    }

    fun purge(ctx: Context, done: (String) -> Unit) {
        val app = ctx.applicationContext
        io.execute {
            val msg = try {
                val session = CloudRuntime.session(app)
                if (session == null) "This phone isn't paired yet." else {
                    (engine ?: ClipboardSyncEngine(session.rtdb, session.crypto, session.deviceId, session.deviceName)).purge()
                    ClipboardHistory.get(app).clear(); "Synced clipboard removed from the cloud and from this phone."
                }
            } catch (e: Exception) { "Couldn't purge: ${e.message}" }
            done(msg)
        }
    }
}

/**
 * The one background context Android 10+ lets read the clipboard (F-045 D7). It subscribes to no screen content
 * and reads no window — see accessibility_service_config.xml. Verified on an emulator for lifecycle only; whether
 * a given phone's OEM build permits the background read must be checked on that phone.
 */
class ClipboardAccessibilityService : AccessibilityService() {
    override fun onServiceConnected() { super.onServiceConnected(); ClipboardController.start(this) }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) { /* intentionally empty */ }
    override fun onInterrupt() {}
}

/** The share-sheet target: "Send to Mac" works everywhere, because the user hands Halo the text explicitly. */
class SendToMacActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent?.takeIf { it.action == Intent.ACTION_SEND }?.getStringExtra(Intent.EXTRA_TEXT)
        if (text.isNullOrBlank()) { finish(); return }
        val app = applicationContext
        ClipboardController.publishText(app, text) { msg -> android.os.Handler(android.os.Looper.getMainLooper()).post { Toast.makeText(app, msg, Toast.LENGTH_SHORT).show() } }
        finish()
    }
}
