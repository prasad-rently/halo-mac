package app.halo.mobile.cloud

/** Who asked for the clipboard stream to run. Only the owner that started it may be the reason it stops. */
enum class ClipboardOwner {
    /** The UI / the user's own "Sync my clipboard" switch, and a paired app launch. Lives until the user switches sync off. */
    USER,
    /** The accessibility service (the one context Android lets read the clipboard in the background). */
    ACCESSIBILITY,
    /** [app.halo.mobile.background.HaloShareService]. Its claim ends when the service is destroyed. */
    SERVICE,
}

/** The side effects of running the stream, so the ownership rules are testable with a fake. */
interface ClipboardBackend {
    /** Open (or re-open) the stream. Idempotent from the caller's view. */
    fun startStream()
    fun stopStream()
    fun startListening()
    fun stopListening()
}

/**
 * Process-wide ownership of the one clipboard stream. The stream is shared by the app, the accessibility service and the
 * foreground service, and a clip must not be delivered twice, so there is exactly one — started by whichever owner
 * arrives first and kept alive until the *last* owner lets go:
 *
 *  - the foreground service releasing its claim (it was destroyed) stops the stream only if nothing else holds it. A
 *    stream the user's own switch or the accessibility service started keeps running: the service did not start it
 *    and must not be the reason it stops;
 *  - [stopAll] is the user's clipboard setting turning off (or disconnecting): every claim is void.
 */
class ClipboardLifecycle(private val backend: ClipboardBackend) {
    private val owners = LinkedHashSet<ClipboardOwner>()

    val isRunning: Boolean @Synchronized get() = owners.isNotEmpty()
    @Synchronized fun owners(): Set<ClipboardOwner> = owners.toSet()

    /** Claim the stream (and (re)open it). */
    @Synchronized fun acquire(owner: ClipboardOwner) { owners.add(owner); backend.startStream(); backend.startListening() }

    /** Let go of [owner]'s claim. The stream stops only when that was the last one. */
    @Synchronized fun release(owner: ClipboardOwner) {
        if (!owners.remove(owner)) return
        if (owners.isEmpty()) { backend.stopStream(); backend.stopListening() }
    }

    /** Re-open the stream for whoever holds it (e.g. the network changed). No-op when nobody does. */
    @Synchronized fun refresh() { if (owners.isNotEmpty()) backend.startStream() }

    @Synchronized fun stopAll() { owners.clear(); backend.stopStream(); backend.stopListening() }
}
