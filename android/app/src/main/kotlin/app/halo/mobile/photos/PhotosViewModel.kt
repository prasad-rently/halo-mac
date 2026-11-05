package app.halo.mobile.photos

import android.app.Application
import android.content.IntentSender
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.halo.photos.CancelToken
import app.halo.photos.Clustering
import app.halo.photos.ConfirmedDeletion
import app.halo.photos.DeleteMode
import app.halo.photos.DeletionRequest
import app.halo.photos.HashedPhoto
import app.halo.photos.MediaAccess
import app.halo.photos.PhotoGroup
import app.halo.photos.PhotoPermissions
import app.halo.photos.ReviewSession
import app.halo.photos.ScanCancelled
import app.halo.photos.ScanEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class Phase { IDLE, SCANNING, READY, DELETING }

data class PhotosUi(
    val access: MediaAccess = MediaAccess.NONE,
    val phase: Phase = Phase.IDLE,
    val done: Int = 0, val total: Int = 0,
    val scanned: Int = 0, val failed: Int = 0, val truncatedFrom: Int? = null,
    val threshold: Int = Clustering.DEFAULT_THRESHOLD,
    val groups: List<PhotoGroup> = emptyList(),
    val marked: Int = 0, val markedBytes: Long = 0, val ignored: Int = 0,
    /** Shown as OUR confirmation dialog (count + size). Null = no dialog. Nothing is deleted while this is non-null. */
    val confirm: DeletionRequest? = null,
    val message: String? = null,
    val scannedOnce: Boolean = false,
    val deleteMode: DeleteMode = PhotoPermissions.deleteMode(Build.VERSION.SDK_INT),
    /** Bumped on any selection change so Compose re-reads `session`. */
    val rev: Int = 0,
)

class PhotosViewModel(app: Application) : AndroidViewModel(app) {
    private val _ui = MutableStateFlow(PhotosUi())
    val ui: StateFlow<PhotosUi> = _ui.asStateFlow()

    /** The system dialog the UI must launch (set after the user confirmed in our dialog). */
    private val _systemDialog = MutableStateFlow<IntentSender?>(null)
    val systemDialog: StateFlow<IntentSender?> = _systemDialog.asStateFlow()

    val thumbs = ThumbnailCache(app)
    var session: ReviewSession = ReviewSession(emptyList()); private set
    private var hashed: List<HashedPhoto> = emptyList()
    private var cancel = CancelToken()
    private var awaiting: ConfirmedDeletion? = null

    fun onPermissionsChanged(granted: Set<String>) {
        _ui.update { it.copy(access = PhotoPermissions.resolve(Build.VERSION.SDK_INT, granted)) }
    }

    fun scan() {
        if (_ui.value.phase == Phase.SCANNING || _ui.value.access == MediaAccess.NONE) return
        cancel = CancelToken()
        val token = cancel
        _ui.update { it.copy(phase = Phase.SCANNING, done = 0, total = 0, message = null, confirm = null) }
        viewModelScope.launch {
            try {
                val res = withContext(Dispatchers.IO) {
                    val refs = MediaStorePhotos.query(getApplication(), Clustering.MAX_PHOTOS + 1)
                    _ui.update { it.copy(total = refs.size) }
                    ScanEngine.hashAll(refs, AndroidThumbnailDecoder(getApplication()), token, parallelism = 3,
                        onProgress = { d, t -> if (d % 8 == 0 || d == t) _ui.update { u -> u.copy(done = d, total = t) } })
                }
                hashed = res.hashed
                _ui.update { it.copy(failed = res.failed, scanned = res.hashed.size, truncatedFrom = res.truncatedFrom, scannedOnce = true) }
                regroup(_ui.value.threshold)
                _ui.update { it.copy(phase = Phase.READY) }
            } catch (_: ScanCancelled) {
                _ui.update { it.copy(phase = if (hashed.isEmpty()) Phase.IDLE else Phase.READY, message = "Scan cancelled.") }
            } catch (e: SecurityException) {
                _ui.update { it.copy(phase = Phase.IDLE, message = "Android blocked access to your photos. Allow photo access and try again.") }
            }
        }
    }

    fun cancelScan() { cancel.cancel() }

    /** Re-cluster the already-hashed photos at a new threshold — instant, no re-decode. Resets marks (they belonged to the old groups). */
    fun regroup(threshold: Int) {
        session = ReviewSession(Clustering.groups(hashed, threshold))
        publish(threshold = threshold)
    }

    fun setThresholdLive(t: Int) { _ui.update { it.copy(threshold = t) } }

    fun toggle(groupId: Long, photoId: Long) {
        val r = session.toggle(groupId, photoId)
        publish(message = if (r == ReviewSession.Toggle.REFUSED_LAST_KEPT) "At least one photo in each group has to stay." else null)
    }
    fun keepBest(groupId: Long) { session.keepBest(groupId); publish() }
    fun keepOnly(groupId: Long, photoId: Long) { session.keepOnly(groupId, photoId); publish() }
    fun ignore(groupId: Long) { session.ignoreGroup(groupId); publish() }

    private fun publish(threshold: Int = _ui.value.threshold, message: String? = null) {
        val plan = session.plan()
        _ui.update { it.copy(threshold = threshold, groups = session.groups, marked = plan.count, markedBytes = plan.totalBytes, ignored = session.ignoredGroupCount, message = message, rev = it.rev + 1) }
    }

    // ---- deletion: our confirmation -> Android's system dialog -> verify what the OS actually did -------------------

    /** Step 1: show OUR dialog (count + total size). Nothing is deleted. */
    fun requestDelete() {
        if (_ui.value.deleteMode != DeleteMode.TRASH_REQUEST) return
        _ui.update { it.copy(confirm = session.requestDeletion()) }
    }

    fun cancelConfirm() { _ui.update { it.copy(confirm = null) } }

    /** Step 2: the user pressed the confirm button. Only now does a [ConfirmedDeletion] exist; hand it to the system dialog. */
    fun confirmDelete() {
        val req = _ui.value.confirm ?: return
        val confirmed = try { req.confirm() } catch (e: IllegalStateException) {
            _ui.update { it.copy(confirm = null, message = "The selection changed — review it and try again.") }; return
        }
        awaiting = confirmed
        _ui.update { it.copy(confirm = null, phase = Phase.DELETING) }
        _systemDialog.value = TrashRequest.intentSender(getApplication<Application>().contentResolver, confirmed)
    }

    fun systemDialogLaunched() { _systemDialog.value = null }

    /** Step 3: the system dialog closed. Whatever the result code says, ask MediaStore what is REALLY gone. */
    fun systemDialogResult() {
        val confirmed = awaiting ?: run { _ui.update { it.copy(phase = Phase.READY) }; return }
        awaiting = null
        viewModelScope.launch {
            val ids = confirmed.plan.items.map { it.id }
            val remaining = withContext(Dispatchers.IO) { MediaStorePhotos.stillPresent(getApplication<Application>().contentResolver, ids) }
            val gone = ids.toSet() - remaining
            val freed = confirmed.plan.items.filter { it.id in gone }.sumOf { it.sizeBytes }
            session.completeDeletion(confirmed, gone)
            hashed = hashed.filter { it.photo.id !in gone }
            publish(message = if (gone.isEmpty()) "Nothing was moved to Trash." else "Moved ${gone.size} photo${if (gone.size == 1) "" else "s"} (${app.halo.mobile.formatBytes(freed)}) to Trash. You can restore them from your Gallery's Trash.")
            _ui.update { it.copy(phase = Phase.READY) }
        }
    }
}
