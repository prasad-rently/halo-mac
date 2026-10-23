package app.halo.mobile

import android.app.Application
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
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

    private val _listen = MutableStateFlow<ListenState>(ListenState.Stopped)
    val listen: StateFlow<ListenState> = _listen.asStateFlow()

    private val _offer = MutableStateFlow<IncomingOffer?>(null)
    val pendingOffer: StateFlow<IncomingOffer?> = _offer.asStateFlow()

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

    private var server: HaloShareServer? = null
    private var client = HaloShareClient(_identity.value)
    private var consentFuture: CompletableFuture<ConsentDecision>? = null
    private var sendJob: Job? = null
    private var scanJob: Job? = null
    private var cancelToken: CancelToken? = null
    @Volatile private var scanCancelled = false

    init { refreshInbox() }

    private fun load(): DeviceIdentity =
        DeviceIdentityStore.loadOrCreate(store, defaultAlias = Build.MODEL ?: "Android", deviceModel = Build.MODEL, deviceType = "mobile")

    val selectedPeer: Peer? get() = _peers.value.firstOrNull { it.id == _selected.value }

    // ── Identity ──────────────────────────────────────────────────────────────────────────────

    fun setAlias(alias: String) {
        DeviceIdentityStore.setAlias(store, alias)
        _identity.value = load()
        client = HaloShareClient(_identity.value)
        if (_listen.value is ListenState.Listening) { stopServer(); startServer() }   // peers must see the new name
    }

    // ── Receive ───────────────────────────────────────────────────────────────────────────────

    /** Listens while the app is visible. (A foreground service for background receive is a later milestone.) */
    fun startServer() {
        if (server != null) return
        _listen.value = ListenState.Starting
        val handler = ConsentHandler { offer -> askConsent(offer) }
        val listener = object : ServerListener {
            override fun onFileReceived(sessionId: String, fileId: String, file: File) { refreshInbox(); _notice.value = "Received ${file.name}" }
            override fun onSessionCompleted(sessionId: String) { refreshInbox() }
            override fun onSessionCancelled(sessionId: String) { refreshInbox(); _notice.value = "The sender cancelled the transfer." }
        }
        val s = HaloShareServer(_identity.value, receiveDirectory, handler, listener)
        server = s
        viewModelScope.launch(Dispatchers.IO) {
            try { _listen.value = ListenState.Listening(s.start(HaloShare.DEFAULT_PORT)) }
            catch (e: Exception) { server = null; _listen.value = ListenState.Failed(e.message ?: "couldn't listen") }
        }
    }

    fun stopServer() {
        resolveConsent(ConsentDecision.DECLINE)       // a prompt left open can't be answered once we stop
        server?.stop(); server = null
        _listen.value = ListenState.Stopped
    }

    /** Called on a server thread; blocks until the person answers. One prompt at a time. */
    private fun askConsent(offer: IncomingOffer): ConsentDecision {
        if (_offer.value != null) return ConsentDecision.DECLINE
        val future = CompletableFuture<ConsentDecision>()
        consentFuture = future
        _offer.value = offer
        return try { future.get() } catch (e: Exception) { ConsentDecision.DECLINE }
    }

    fun resolveConsent(decision: ConsentDecision) {
        _offer.value = null
        consentFuture?.complete(decision); consentFuture = null
    }

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
            val found = SubnetScanner(client).scan(onFound = { merge(it) }, isCancelled = { scanCancelled })
            found.forEach { merge(it) }
            _scanning.value = false
            if (_peers.value.isEmpty()) _notice.value = "No devices found. Make sure the other device has HaloShare or LocalSend open on the same Wi-Fi — or add its address below."
        }
    }

    fun stopScan() { scanCancelled = true; scanJob?.cancel(); _scanning.value = false }

    private fun merge(peer: Peer) {
        _peers.update { list -> (list.filter { it.id != peer.id } + peer).sortedBy { it.alias.lowercase() } }
        if (_selected.value == null) _selected.value = peer.id
    }

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
            resolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { name = c.getString(it) }
                    c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 }?.let { if (!c.isNull(it)) size = c.getLong(it) }
                }
            }
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

    override fun onCleared() { server?.stop(); super.onCleared() }
}
