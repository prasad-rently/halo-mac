package app.halo.mobile

import android.app.Application
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.halo.mobile.background.BackgroundPrefs
import app.halo.mobile.background.HaloShareService
import app.halo.mobile.background.ReceiverHost
import app.halo.share.CancelToken
import app.halo.share.ConsentDecision
import app.halo.share.ConsentHandler
import app.halo.share.DeviceIdentity
import app.halo.share.DeviceIdentityStore
import app.halo.share.HaloShare
import app.halo.share.HaloShareClient
import app.halo.share.HaloShareException
import app.halo.share.HaloShareServer
import app.halo.share.IncomingOffer
import app.halo.share.KeyValueStore
import app.halo.share.LocalNetwork
import app.halo.share.OutgoingFile
import app.halo.share.Peer
import app.halo.share.SendOutcome
import app.halo.share.ServerListener
import app.halo.share.SubnetScanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.CompletableFuture

sealed interface ListenState {
    object Stopped : ListenState
    object Starting : ListenState
    data class Listening(val port: Int) : ListenState
    data class Failed(val why: String) : ListenState
}

sealed interface TransferState {
    object Idle : TransferState
    data class Sending(val fileName: String, val sent: Long, val total: Long, val overallSent: Long, val overallTotal: Long) : TransferState
    data class Finished(val message: String) : TransferState
    data class Failed(val why: String) : TransferState
    val isBusy: Boolean get() = this is Sending
}

data class InboxItem(val file: File, val size: Long, val modified: Long) { val name: String get() = file.name }

/** The one object the UI observes: identity, the receiver, discovery, sending, and the consent hand-off. */
class AppViewModel(app: Application) : AndroidViewModel(app) {

    private val prefs = app.getSharedPreferences("haloshare", android.content.Context.MODE_PRIVATE)
    private val store = object : KeyValueStore {
        override fun get(key: String): String? = prefs.getString(key, null)
        override fun put(key: String, value: String) { prefs.edit().putString(key, value).apply() }
    }

    private val _identity = MutableStateFlow(load())
    val identity: StateFlow<DeviceIdentity> = _identity.asStateFlow()

    // F-055: the receiver is process-wide (ReceiverHost) so the foreground service and this screen share one server.
    val listen: StateFlow<ListenState> = ReceiverHost.listen
    val pendingOffer: StateFlow<IncomingOffer?> = ReceiverHost.offer

    private val bg = BackgroundPrefs(app)
    private val _backgroundReceive = MutableStateFlow(bg.enabled)
    val backgroundReceive: StateFlow<Boolean> = _backgroundReceive.asStateFlow()
    private val _pausedBySystem = MutableStateFlow(bg.pausedBySystem)
    val pausedBySystem: StateFlow<Boolean> = _pausedBySystem.asStateFlow()

    /** Files handed to us by the Sharesheet, waiting for the person to pick a device (F-055 FR-B3). */
    private val _shared = MutableStateFlow<List<Uri>>(emptyList())
    val shared: StateFlow<List<Uri>> = _shared.asStateFlow()

    private val _inbox = MutableStateFlow<List<InboxItem>>(emptyList())
    val inbox: StateFlow<List<InboxItem>> = _inbox.asStateFlow()

    private val _peers = MutableStateFlow<List<Peer>>(emptyList())
    val peers: StateFlow<List<Peer>> = _peers.asStateFlow()

    private val _selected = MutableStateFlow<String?>(null)
    val selectedPeerId: StateFlow<String?> = _selected.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _transfer = MutableStateFlow<TransferState>(TransferState.Idle)
    val transfer: StateFlow<TransferState> = _transfer.asStateFlow()

    private val _notice = MutableStateFlow<String?>(null)
    val notice: StateFlow<String?> = _notice.asStateFlow()

    val receiveDirectory: File = (app.getExternalFilesDir("Received") ?: File(app.filesDir, "Received")).also { it.mkdirs() }

    private var client = HaloShareClient(_identity.value)
    private var sendJob: Job? = null
    private var scanJob: Job? = null
    private var cancelToken: CancelToken? = null
    @Volatile private var scanCancelled = false

    init {
        refreshInbox()
        viewModelScope.launch {
            ReceiverHost.events.collect { e -> when (e) {
                is ReceiverHost.Event.Received -> { refreshInbox(); _notice.value = "Received ${e.name}" }
                ReceiverHost.Event.InboxChanged -> refreshInbox()
                ReceiverHost.Event.SenderCancelled -> { refreshInbox(); _notice.value = "The sender cancelled the transfer." }
            } }
        }
    }

    private fun load(): DeviceIdentity = app.halo.mobile.background.HaloIdentity.load(getApplication())

    val selectedPeer: Peer? get() = _peers.value.firstOrNull { it.id == _selected.value }

    // ── Identity ──────────────────────────────────────────────────────────────────────────────

    fun setAlias(alias: String) {
        DeviceIdentityStore.setAlias(store, alias)
        _identity.value = load()
        client = HaloShareClient(_identity.value)
        ReceiverHost.restart(getApplication(), _identity.value)   // peers must see the new name
    }

    // ── Receive ───────────────────────────────────────────────────────────────────────────────

    /** Listens while the app is visible (and, if the user opted in, in the background via [HaloShareService]). */
    fun startServer() = ReceiverHost.start(getApplication(), _identity.value)

    /**
     * Only stops the receiver when nothing else will keep it: the foreground service must actually be running. Keying this
     * on the toggle alone left a listener open with no service and no notification whenever Android had ended the service
     * (the Android 15 six-hour limit, a refused start) while the screen was up.
     */
    fun stopServer() { if (!ReceiverHost.serviceActive) ReceiverHost.stop(getApplication()) }

    fun resolveConsent(decision: ConsentDecision) = ReceiverHost.resolve(decision)

    // ── Background receiving (F-055 FR-B1/B2) ─────────────────────────────────────────────────

    fun setBackgroundReceive(on: Boolean) {
        bg.enabled = on; _backgroundReceive.value = on
        if (on) { bg.pausedBySystem = false; _pausedBySystem.value = false; HaloShareService.start(getApplication()) } else HaloShareService.stop(getApplication())
    }

    /** Called when the app comes to the front: re-assert the service the user asked for, and pick up a system pause. */
    fun syncBackgroundState() {
        _backgroundReceive.value = bg.enabled; _pausedBySystem.value = bg.pausedBySystem
        if (bg.enabled && !bg.pausedBySystem && !ReceiverHost.serviceActive) HaloShareService.start(getApplication())
    }

    // ── Sharesheet (F-055 FR-B3) ──────────────────────────────────────────────────────────────

    /** What the person is about to send, by name — the share card shows it so a swapped-in second share is visible. */
    private val _sharedLabels = MutableStateFlow<List<String>>(emptyList())
    val sharedLabels: StateFlow<List<String>> = _sharedLabels.asStateFlow()

    fun stageShared(uris: List<Uri>) {
        _shared.value = uris; _sharedLabels.value = emptyList()
        if (uris.isEmpty()) return
        _notice.value = "${uris.size} shared item(s) ready — choose a device, then tap Send."
        val resolver = getApplication<Application>().contentResolver
        viewModelScope.launch(Dispatchers.IO) {
            val names = uris.take(3).map { u -> runCatching { displayName(resolver, u) }.getOrNull() ?: "(unreadable item)" }
            if (_shared.value == uris) _sharedLabels.value = names
        }
    }
    fun clearShared() { _shared.value = emptyList(); _sharedLabels.value = emptyList() }
    fun sendShared() { val u = _shared.value; if (u.isNotEmpty()) { send(u); clearShared() } }

    private fun displayName(resolver: android.content.ContentResolver, uri: Uri): String? =
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { c.getString(it) } else null
        }?.filter { !it.isISOControl() }?.take(80)

    fun refreshInbox() {
        _inbox.value = receiveDirectory.walkTopDown().filter { it.isFile && !it.name.startsWith(".") }
            .map { InboxItem(it, it.length(), it.lastModified()) }.sortedByDescending { it.modified }.toList()
    }

    fun deleteInboxItem(item: InboxItem) { item.file.delete(); refreshInbox() }

    // ── Discovery ─────────────────────────────────────────────────────────────────────────────

    fun scan() {
        if (_scanning.value) return
        _scanning.value = true; _notice.value = null; scanCancelled = false
        scanJob = viewModelScope.launch(Dispatchers.IO) {
            // Multicast (F-055 FR-B4) and the /24 HTTP scan run together; whichever sees a peer first wins, duplicates merge by fingerprint.
            val multicast = launch { app.halo.mobile.background.MulticastScope.run(getApplication(), _identity.value.deviceInfo(), onFound = { mergeUnverified(it) }, isCancelled = { scanCancelled }) }
            val found = SubnetScanner(client).scan(onFound = { merge(it) }, isCancelled = { scanCancelled })
            found.forEach { merge(it) }
            multicast.join()
            _scanning.value = false
            if (_peers.value.isEmpty()) _notice.value = "No devices found. Make sure the other device has HaloShare or LocalSend open on the same Wi-Fi — or add its address below."
        }
    }

    fun stopScan() { scanCancelled = true; scanJob?.cancel(); _scanning.value = false }

    private fun merge(peer: Peer) {
        _peers.update { list -> (list.filter { it.id != peer.id } + peer).sortedBy { it.alias.lowercase() } }
        if (_selected.value == null) _selected.value = peer.id
    }

    /**
     * A multicast datagram is unauthenticated, and a device's fingerprint is public (it is in every announcement), so a
     * second host claiming a fingerprint we already hold must not silently take over that entry — that would redirect
     * the next send. First sighting wins; an address that actually answered over HTTP (the /24 scan, manual add) is
     * authoritative and still replaces it via [merge].
     */
    private fun mergeUnverified(peer: Peer) { if (_peers.value.none { it.id == peer.id }) merge(peer) }

    fun select(id: String) { _selected.value = id }

    /** MR-DI-2: manual `host[:port]`. */
    fun addManual(text: String): Boolean {
        val parsed = LocalNetwork.parseHostPort(text)
        if (parsed == null) { _notice.value = "That doesn't look like an address. Try 192.168.1.20 or 192.168.1.20:53317."; return false }
        val (host, port) = parsed
        viewModelScope.launch(Dispatchers.IO) {
            val peer = client.probe(host, port, timeoutMs = 4000)
            if (peer != null) { merge(peer); _selected.value = peer.id; _notice.value = "Found ${peer.alias}." }
            else _notice.value = "No HaloShare device answered at $host:$port."
        }
        return true
    }

    // ── Send ──────────────────────────────────────────────────────────────────────────────────

    fun send(uris: List<Uri>) {
        val peer = selectedPeer ?: run { _notice.value = "Choose a device first."; return }
        if (_transfer.value.isBusy) return
        val resolver = getApplication<Application>().contentResolver
        val files = uris.mapNotNull { uri ->
            var name = uri.lastPathSegment ?: "file"; var size = -1L
            // A shared URI is another app's input: a revoked grant or a provider that refuses us throws, and that must be
            // "couldn't read", not a crash on the main thread.
            try {
                resolver.query(uri, null, null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { name = c.getString(it) }
                        c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 }?.let { if (!c.isNull(it)) size = c.getLong(it) }
                    }
                }
            } catch (e: Exception) { return@mapNotNull null }
            if (size < 0) return@mapNotNull null
            OutgoingFile(name = name, size = size, mimeType = resolver.getType(uri) ?: "application/octet-stream",
                open = { resolver.openInputStream(uri) ?: throw java.io.IOException("cannot open $name") })
        }
        if (files.isEmpty()) { _notice.value = "Couldn't read the chosen files."; return }
        run(files, peer)
    }

    private fun run(files: List<OutgoingFile>, peer: Peer) {
        _notice.value = null
        val token = CancelToken().also { cancelToken = it }
        sendJob = viewModelScope.launch(Dispatchers.IO) {
            _transfer.value = TransferState.Sending(files.first().name, 0, files.first().size, 0, files.sumOf { it.size })
            _transfer.value = try {
                when (client.send(files, peer, token) { p ->
                    _transfer.value = TransferState.Sending(p.fileName, p.sent, p.total, p.overallSent, p.overallTotal)
                }) {
                    SendOutcome.Completed -> TransferState.Finished("Sent ${if (files.size == 1) files[0].name else "${files.size} files"} to ${peer.alias}.")
                    SendOutcome.Declined -> TransferState.Finished("${peer.alias} declined the transfer.")
                    SendOutcome.NothingToSend -> TransferState.Finished("Nothing needed sending.")
                }
            } catch (e: HaloShareException.Cancelled) { TransferState.Finished("Cancelled.")
            } catch (e: Exception) { TransferState.Failed(e.message ?: "Transfer failed.") }
        }
    }

    fun cancelSend() { cancelToken?.cancel() }
    fun dismissTransferResult() { if (!_transfer.value.isBusy) _transfer.value = TransferState.Idle }
    fun dismissNotice() { _notice.value = null }

    /** Debug aid: a throw-away file of non-text bytes, so the send path can be driven without the system picker. */
    fun sendTestFile(megabytes: Int = 5) {
        val peer = selectedPeer ?: run { _notice.value = "Choose a device first."; return }
        val bytes = megabytes.toLong() shl 20
        val file = File(getApplication<Application>().cacheDir, "halo-test-${megabytes}MB.bin").apply {
            outputStream().buffered().use { o -> val rnd = java.security.SecureRandom(); val b = ByteArray(1 shl 16); var w = 0L; while (w < bytes) { rnd.nextBytes(b); o.write(b, 0, minOf(b.size.toLong(), bytes - w).toInt()); w += b.size } }
        }
        dismissTransferResult()
        run(listOf(OutgoingFile.fromFile(file)), peer)
    }

    override fun onCleared() { stopServer(); super.onCleared() }
}
