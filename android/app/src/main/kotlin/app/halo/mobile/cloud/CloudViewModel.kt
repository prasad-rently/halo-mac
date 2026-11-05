package app.halo.mobile.cloud

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.halo.cloud.CryptoService
import app.halo.cloud.FirebaseHosts
import app.halo.cloud.FirebaseRtdbClient
import app.halo.cloud.KeyCheck
import app.halo.cloud.PairingConfirmation
import app.halo.cloud.PairingPayload
import app.halo.cloud.ProfileLoad
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

/** Why a paired phone shows no profile. */
enum class ProfileProblem { UNAVAILABLE, KEY_LOST }

private fun problemOf(r: ProfileLoad<*>): ProfileProblem? = when (r) {
    is ProfileLoad.Unavailable -> ProfileProblem.UNAVAILABLE
    ProfileLoad.KeyLost -> ProfileProblem.KEY_LOST
    else -> null
}

sealed interface PairUi {
    object Idle : PairUi
    data class Working(val what: String) : PairUi
    /** [hostWarning]: the database host is not a Firebase address (H-15) — shown, never silently accepted. */
    data class NeedsPassphrase(val payload: PairingPayload, val hostWarning: String? = null) : PairUi
    /** The database held nothing encrypted, so the passphrase could not be verified: ask for it a second time. [error] is a failed confirmation. */
    data class NeedsConfirmation(val payload: PairingPayload, val error: String? = null) : PairUi
    data class Failed(val why: String) : PairUi
}

/** Signed in and key derived, waiting for the user to retype the passphrase. Kept out of the UI state so the passphrase never sits in a StateFlow. */
private class PendingPairing(val payload: PairingPayload, val passphrase: String, val key: ByteArray, val client: FirebaseRtdbClient)

data class LineUi(val line: SimLine, val enabled: Boolean)

/** Pairing, SMS sync and clipboard sync — the whole cloud side of the app, kept off the HaloShare view model. */
class CloudViewModel(app: Application) : AndroidViewModel(app) {
    private val ctx: Context get() = getApplication()
    private val store = CloudStore(app)
    val prefs = CloudPrefs(app)

    private val initialLoad = store.loadResult()
    private val _profile = MutableStateFlow((initialLoad as? ProfileLoad.Loaded)?.value)
    val profile: StateFlow<CloudProfile?> = _profile.asStateFlow()

    /** Why there is no profile when the phone may well be paired: the saved connection can't be opened right now / ever again. Null = simply not paired (or fine). */
    private val _problem = MutableStateFlow(problemOf(initialLoad))
    val profileProblem: StateFlow<ProfileProblem?> = _problem.asStateFlow()

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
    val historyWarning get() = ClipboardHistory.get(ctx).warning
    val historyKeyLost get() = ClipboardHistory.get(ctx).keyLost
    /** The explicit reset after the history's secure key was lost (Keystore work: off the main thread). */
    fun resetHistory() { viewModelScope.launch(Dispatchers.IO) { ClipboardHistory.get(ctx).resetLostKey() } }
    /** The storage warning promises a retry; this is what makes it true when no new clip arrives to trigger a save. Off the main thread: it touches the Keystore. */
    fun retryHistory() { viewModelScope.launch(Dispatchers.IO) { ClipboardHistory.get(ctx).retry() } }
    val clipStatus: StateFlow<String> = ClipboardController.status

    init { if (_profile.value != null) startServices() }

    private fun startServices() {
        if (prefs.smsEnabled) SyncScheduler.schedulePeriodic(ctx)
        if (prefs.clipboardEnabled) ClipboardController.start(ctx)
    }

    /**
     * Re-read the saved connection. Called on resume and from "Try again" while [profileProblem] is showing: a Keystore that
     * was busy a moment ago usually is not now. Never writes anything — an unreadable profile is only ever replaced by the
     * user pairing again after [resetLostProfile].
     */
    fun refreshProfile() {
        viewModelScope.launch(Dispatchers.IO) {
            val r = store.loadResult()
            if (r is ProfileLoad.Loaded) {
                CloudRuntime.reset()
                val first = _profile.value == null
                _profile.value = r.value; _problem.value = null
                if (first) startServices()
            } else if (_profile.value == null) _problem.value = problemOf(r)
        }
    }

    /** The user chose to give up on a profile whose key is gone: forget it, make a fresh key, and show the pairing panel. */
    fun resetLostProfile() {
        viewModelScope.launch(Dispatchers.IO) {
            // The confirmation dialog may have been up for a while, and "key lost" can be a Keystore that was not ready: look
            // again, and never delete a profile that has become readable (or is merely unavailable) in the meantime.
            when (val r = store.loadResult()) {
                is ProfileLoad.Loaded -> { CloudRuntime.reset(); val first = _profile.value == null; _profile.value = r.value; _problem.value = null; if (first) startServices(); return@launch }
                is ProfileLoad.Unavailable -> { _problem.value = ProfileProblem.UNAVAILABLE; return@launch }
                else -> {}
            }
            disconnect()
            runCatching { SecretBox.ensureKey() }
            _problem.value = null
        }
    }

    fun dismissNotice() { _notice.value = null }

    // ── Pairing ───────────────────────────────────────────────────────────────────────────────

    /** The desktop's pairing code (base64 of the payload JSON), pasted or scanned. */
    fun submitCode(raw: String) {
        if (_problem.value != null) { _pair.value = PairUi.Failed("This phone has a saved connection that can't be opened right now. Try again, or reset it first."); return }
        val text = raw.filterNot { it.isWhitespace() }
        if (text.isEmpty()) { _pair.value = PairUi.Failed("Paste the pairing code from your Mac first."); return }
        val payload = try { PairingPayload.decode(text) } catch (e: Exception) { _pair.value = PairUi.Failed("That doesn't look like a Halo pairing code."); return }
        when {
            !payload.isValid -> _pair.value = PairUi.Failed("The pairing code is damaged (its checksum doesn't match). Generate a fresh one on your Mac.")
            payload.salt == null || payload.salt!!.size < CryptoService.MINIMUM_SALT_BYTES -> _pair.value = PairUi.Failed("The pairing code's key salt is invalid.")
            payload.iterations < CryptoService.MINIMUM_ITERATIONS -> _pair.value = PairUi.Failed("The pairing code asks for a key-derivation cost below Halo's minimum.")
            !payload.firebaseConfig.databaseURL.startsWith("https://") && !DebugEndpoints.applies(payload.firebaseConfig.databaseURL) -> _pair.value = PairUi.Failed("The pairing code's database address isn't https.")
            else -> _pair.value = PairUi.NeedsPassphrase(payload, if (DebugEndpoints.applies(payload.firebaseConfig.databaseURL)) null else FirebaseHosts.warning(payload.firebaseConfig.databaseURL))
        }
    }

    fun cancelPairing() { pending = null; _pair.value = PairUi.Idle }

    private var pending: PendingPairing? = null

    /**
     * Step 1: derive the key, sign in, and try the passphrase against real data. If the database holds
     * nothing encrypted the check cannot vouch for it ([PairingConfirmation.required]), so stop and ask for
     * the passphrase a second time ([confirm]) before anything is saved. Otherwise finish straight away.
     */
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
                val check = KeyCheck.verify(client, crypto)
                if (check == KeyCheck.Result.MISMATCH) {
                    _pair.value = PairUi.Failed("That passphrase doesn't open the data on your Mac. Check it and try again.")
                    return@launch
                }
                if (PairingConfirmation.required(check)) {
                    pending = PendingPairing(payload, passphrase, key, client)
                    _pair.value = PairUi.NeedsConfirmation(payload)
                    return@launch
                }
                finishPairing(payload, key, client)
            } catch (e: Exception) {
                _pair.value = PairUi.Failed(e.message ?: "Couldn't connect.")
            }
        }
    }

    /** Step 2 (empty database only): the passphrase typed again must match the first entry before the profile is saved. */
    fun confirm(again: String) {
        val p = pending ?: run { _pair.value = PairUi.Failed("Pairing was interrupted. Start again."); return }
        if (!PairingConfirmation.matches(p.passphrase, again)) {
            _pair.value = PairUi.NeedsConfirmation(p.payload, "The two passphrases don't match. Type the exact passphrase you set on your Mac.")
            return
        }
        viewModelScope.launch(Dispatchers.Default) {
            try { finishPairing(p.payload, p.key, p.client) }
            catch (e: Exception) { _pair.value = PairUi.Failed(e.message ?: "Couldn't connect.") }
        }
    }

    private fun finishPairing(payload: PairingPayload, key: ByteArray, client: FirebaseRtdbClient) {
        _warning.value = if (client.checkPublicAccess() == FirebaseRtdbClient.PublicAccess.OPEN)
            "Your Realtime Database is open to the internet (test-mode rules). Message text stays encrypted, but device names and timestamps are readable by anyone. Publish the owner-only rules in docs/specs/firebase-rules.json (Realtime Database → Rules; steps in docs/specs/firebase-setup.md)." else null

        val profile = CloudProfile(payload.firebaseConfig, payload.auth, payload.saltBase64, payload.iterations, Base64.getEncoder().encodeToString(key), epoch = java.util.UUID.randomUUID().toString())
        store.save(profile); CloudRuntime.reset()
        pending = null
        _profile.value = profile; _problem.value = null; _pair.value = PairUi.Idle
    }

    fun disconnect() {
        SyncScheduler.cancelAll(ctx); ClipboardController.stop()
        store.clear(); prefs.clearAll(); PrefsSyncState(ctx).clear(); ClipboardHistory.get(ctx).clear(); CloudRuntime.reset()
        _profile.value = null; _lines.value = emptyList(); _smsEnabled.value = false; _clipEnabled.value = false; pending = null; _pair.value = PairUi.Idle; _warning.value = null
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

    /** H-14: give the messages the engine parked another go. */
    fun retrySkipped() {
        viewModelScope.launch(Dispatchers.IO) {
            val r = SmsSyncRunner.retrySkipped(ctx)
            _notice.value = r.error ?: if (r.quarantined > 0) "${r.quarantined} message(s) still couldn't be synced." else "Retried — ${prefs.lastSyncSummary}."
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

    /** Send one history item (or any text) to the Mac. Same path as "Send clipboard": filter, dedupe and history all apply. */
    fun sendClipText(text: String) { ClipboardController.publishText(ctx, text) { _clipNotice.value = it } }

    fun copy(item: ClipItem) { ClipboardController.copyToClipboard(ctx, item); _clipNotice.value = "Copied." }
    fun purgeClipboard() = ClipboardController.purge(ctx) { _clipNotice.value = it }

    fun accessibilityEnabled(): Boolean {
        val me = ComponentName(ctx, ClipboardAccessibilityService::class.java).flattenToString()
        val enabled = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
        return enabled.split(':').any { it.equals(me, ignoreCase = true) }
    }
}
