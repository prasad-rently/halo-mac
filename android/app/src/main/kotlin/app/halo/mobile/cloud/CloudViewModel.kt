package app.halo.mobile.cloud

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.halo.cloud.CryptoService
import app.halo.cloud.FirebaseRtdbClient
import app.halo.cloud.KeyCheck
import app.halo.cloud.PairingPayload
import app.halo.cloud.SimLine
import app.halo.cloud.SmsSyncEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import java.util.Base64

sealed interface PairUi {
    object Idle : PairUi
    data class Working(val what: String) : PairUi
    data class NeedsPassphrase(val payload: PairingPayload) : PairUi
    data class Failed(val why: String) : PairUi
}

data class LineUi(val line: SimLine, val enabled: Boolean)

/** Pairing, SMS sync and clipboard sync — the whole cloud side of the app, kept off the HaloShare view model. */
class CloudViewModel(app: Application) : AndroidViewModel(app) {
    private val ctx: Context get() = getApplication()
    private val store = CloudStore(app)
    val prefs = CloudPrefs(app)

    private val _profile = MutableStateFlow(store.load())
    val profile: StateFlow<CloudProfile?> = _profile.asStateFlow()

    private val _pair = MutableStateFlow<PairUi>(PairUi.Idle)
    val pair: StateFlow<PairUi> = _pair.asStateFlow()

    private val _warning = MutableStateFlow<String?>(null)
    /** Connected, but something the user should fix (an open database). */
    val warning: StateFlow<String?> = _warning.asStateFlow()

    // SMS and clipboard report separately: one tab must never show the other's result.
    private val _notice = MutableStateFlow<String?>(null)
    val notice: StateFlow<String?> = _notice.asStateFlow()
    private val _clipNotice = MutableStateFlow<String?>(null)
    val clipNotice: StateFlow<String?> = _clipNotice.asStateFlow()

    private val _lines = MutableStateFlow<List<LineUi>>(emptyList())
    val lines: StateFlow<List<LineUi>> = _lines.asStateFlow()

    private val _smsEnabled = MutableStateFlow(prefs.smsEnabled)
    val smsEnabled: StateFlow<Boolean> = _smsEnabled.asStateFlow()
    private val _clipEnabled = MutableStateFlow(prefs.clipboardEnabled)
    val clipEnabled: StateFlow<Boolean> = _clipEnabled.asStateFlow()
    private val _clipFilter = MutableStateFlow(prefs.clipboardFilter)
    val clipFilter: StateFlow<Boolean> = _clipFilter.asStateFlow()

    val syncing: StateFlow<Boolean> = SmsSyncRunner.running
    val syncTick: StateFlow<Int> = SmsSyncRunner.tick
    val history get() = ClipboardHistory.get(ctx).items
    val clipStatus: StateFlow<String> = ClipboardController.status

    init {
        if (_profile.value != null) {
            if (prefs.smsEnabled) SyncScheduler.schedulePeriodic(ctx)
            if (prefs.clipboardEnabled) ClipboardController.start(ctx)
        }
    }

    fun dismissNotice() { _notice.value = null }

    // ── Pairing ───────────────────────────────────────────────────────────────────────────────

    /** The desktop's pairing code (base64 of the payload JSON), pasted or scanned. */
    fun submitCode(raw: String) {
        val text = raw.filterNot { it.isWhitespace() }
        if (text.isEmpty()) { _pair.value = PairUi.Failed("Paste the pairing code from your Mac first."); return }
        val payload = try { PairingPayload.decode(text) } catch (e: Exception) { _pair.value = PairUi.Failed("That doesn't look like a Halo pairing code."); return }
        when {
            !payload.isValid -> _pair.value = PairUi.Failed("The pairing code is damaged (its checksum doesn't match). Generate a fresh one on your Mac.")
            payload.salt == null || payload.salt!!.size < CryptoService.MINIMUM_SALT_BYTES -> _pair.value = PairUi.Failed("The pairing code's key salt is invalid.")
            payload.iterations < CryptoService.MINIMUM_ITERATIONS -> _pair.value = PairUi.Failed("The pairing code asks for a key-derivation cost below Halo's minimum.")
            !payload.firebaseConfig.databaseURL.startsWith("https://") && !DebugEndpoints.applies(payload.firebaseConfig.databaseURL) -> _pair.value = PairUi.Failed("The pairing code's database address isn't https.")
            else -> _pair.value = PairUi.NeedsPassphrase(payload)
        }
    }

    fun cancelPairing() { _pair.value = PairUi.Idle }

    /** Derive the key, prove it against real data, prove the connection, then save. */
    fun connect(payload: PairingPayload, passphrase: String) {
        if (passphrase.isEmpty()) { _pair.value = PairUi.Failed("Enter the encryption passphrase you set on your Mac."); return }
        viewModelScope.launch(Dispatchers.Default) {
            try {
                _pair.value = PairUi.Working("Deriving your key…")                    // 600k PBKDF2 rounds: seconds on a phone
                val key = CryptoService.deriveKey(passphrase, payload.salt!!, payload.iterations)
                val crypto = CryptoService(key)

                _pair.value = PairUi.Working("Signing in to your Firebase…")
                val client = newRtdbClient(payload.firebaseConfig, payload.auth)
                client.testConnection()

                _pair.value = PairUi.Working("Checking the passphrase…")
                if (KeyCheck.verify(client, crypto) == KeyCheck.Result.MISMATCH) {
                    _pair.value = PairUi.Failed("That passphrase doesn't open the data on your Mac. Check it and try again.")
                    return@launch
                }
                _warning.value = if (client.checkPublicAccess() == FirebaseRtdbClient.PublicAccess.OPEN)
                    "Your Realtime Database is open to the internet (test-mode rules). Message text stays encrypted, but device names and timestamps are readable by anyone. Publish the owner-only rules from docs/specs/firebase-setup.md." else null

                val profile = CloudProfile(payload.firebaseConfig, payload.auth, payload.saltBase64, payload.iterations, Base64.getEncoder().encodeToString(key), epoch = java.util.UUID.randomUUID().toString())
                store.save(profile); CloudRuntime.reset()
                _profile.value = profile; _pair.value = PairUi.Idle
            } catch (e: Exception) {
                _pair.value = PairUi.Failed(e.message ?: "Couldn't connect.")
            }
        }
    }

    fun disconnect() {
        SyncScheduler.cancelAll(ctx); ClipboardController.stop()
        store.clear(); prefs.clearAll(); PrefsSyncState(ctx).clear(); ClipboardHistory.get(ctx).clear(); CloudRuntime.reset()
        _profile.value = null; _lines.value = emptyList(); _smsEnabled.value = false; _clipEnabled.value = false; _pair.value = PairUi.Idle; _warning.value = null
    }

    var deviceName: String get() = store.deviceName; set(v) { store.deviceName = v; CloudRuntime.reset() }

    // ── SMS ───────────────────────────────────────────────────────────────────────────────────

    fun setSmsEnabled(on: Boolean) {
        prefs.smsEnabled = on; _smsEnabled.value = on
        if (on) { SyncScheduler.schedulePeriodic(ctx); syncNow() } else SyncScheduler.cancelAll(ctx)
    }

    fun syncNow(reconcile: Boolean = false) {
        viewModelScope.launch(Dispatchers.IO) {
            val r = SmsSyncRunner.run(ctx, forceReconcile = reconcile)
            _notice.value = r.error ?: "Synced — ${prefs.lastSyncSummary}."
            refreshLines()
        }
    }

    fun extendHistory(days: Int) {
        viewModelScope.launch(Dispatchers.IO) {
            val r = SmsSyncRunner.extend(ctx, days)
            _notice.value = r.error ?: "Synced $days days of history — ${prefs.lastSyncSummary}."
        }
    }

    /** Re-read the SIM lines and each one's cloud-side toggle (the Mac may have changed it). */
    fun refreshLines() {
        viewModelScope.launch(Dispatchers.IO) {
            val session = try { CloudRuntime.session(ctx) } catch (e: Exception) { null } ?: return@launch
            val lines = try { AndroidSmsSource(ctx, prefs).lines() } catch (e: SecurityException) { _lines.value = emptyList(); return@launch }
            _lines.value = lines.map { l ->
                val flag = try { (session.rtdb.get("sms/${session.rtdb.uid}/${session.deviceId}/lines/${l.subscriptionId}/syncEnabled") as? JsonPrimitive)?.booleanOrNull } catch (e: Exception) { null }
                LineUi(l, flag ?: true)
            }
        }
    }

    fun setLineEnabled(sub: Int, on: Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            val session = try { CloudRuntime.session(ctx) } catch (e: Exception) { null } ?: return@launch
            try {
                SmsSyncEngine(session.rtdb, session.crypto, session.deviceId, session.deviceName, AndroidSmsSource(ctx, prefs), PrefsSyncState(ctx), pairingEpoch = session.profile.epoch).setLineEnabled(sub, on)
                _lines.value = _lines.value.map { if (it.line.subscriptionId == sub) it.copy(enabled = on) else it }
            } catch (e: Exception) { _notice.value = "Couldn't change that line: ${e.message}" }
        }
    }

    fun saveLine(sub: Int, label: String, number: String) { prefs.setLine(sub, label, number); syncNow(); }

    private fun parseList(text: String) = text.split(',', '\n', ';').map { it.trim() }.filter { it.isNotEmpty() }.toSet()
    fun setFilters(allow: String, deny: String) { prefs.allow = parseList(allow); prefs.deny = parseList(deny); _notice.value = "Sender filters saved." }

    // ── Clipboard ─────────────────────────────────────────────────────────────────────────────

    fun setClipboardEnabled(on: Boolean) {
        prefs.clipboardEnabled = on; _clipEnabled.value = on
        if (on) ClipboardController.start(ctx) else ClipboardController.stop()
    }

    fun setClipboardFilter(on: Boolean) { prefs.clipboardFilter = on; _clipFilter.value = on }

    /** Foreground read — always permitted — so this works on every Android version. */
    fun sendClipboardNow() {
        val text = ClipboardController.readClipboard(ctx)
        if (text == null) { _clipNotice.value = "Your clipboard is empty (or Android didn't let Halo read it — try again with Halo open)."; return }
        ClipboardController.publishText(ctx, text) { _clipNotice.value = it }
    }

    fun copy(item: ClipItem) { ClipboardController.copyToClipboard(ctx, item); _clipNotice.value = "Copied." }
    fun purgeClipboard() = ClipboardController.purge(ctx) { _clipNotice.value = it }

    fun accessibilityEnabled(): Boolean {
        val me = ComponentName(ctx, ClipboardAccessibilityService::class.java).flattenToString()
        val enabled = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
        return enabled.split(':').any { it.equals(me, ignoreCase = true) }
    }
}
