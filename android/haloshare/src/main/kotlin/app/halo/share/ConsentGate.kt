package app.halo.share

import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * The one-prompt-at-a-time consent rule, lifted out of the Android layer so it can be tested on the JVM.
 *
 * - **One prompt at a time**, claimed atomically: a second offer arriving while one is open is declined at once.
 *   (The earlier check-then-set let two concurrent offers both through; the loser then waited forever on a future
 *   nobody could complete.)
 * - **Unanswered in the background ⇒ declined.** While [isVisible] is true the prompt waits for the person as long as
 *   it takes; once the UI is not visible a notification is raised via [ask]'s `showPrompt` and the clock starts. A
 *   prompt opened on screen and left there when the app goes away gets the same treatment, instead of blocking every
 *   later offer invisibly.
 * - **A declined / unanswered sender is cooled off** for [coolOffMs]: anyone on the LAN can POST `prepare-upload` in a
 *   loop, and without this each decline would immediately raise the next heads-up notification.
 * - **A stale answer is ignored**: [resolve] can carry the prompt's id, so an Accept tapped on an old notification
 *   cannot approve a different, newer offer.
 */
class ConsentGate(
    private val backgroundTimeoutMs: Long = 90_000,
    private val coolOffMs: Long = 30_000,
    private val pollMs: Long = 200,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val lock = Any()
    private var future: CompletableFuture<ConsentDecision>? = null
    private var currentId = 0L
    private var seq = 0L
    private val coolOff = ConcurrentHashMap<String, Long>()

    /** Whether a prompt is open. */
    val isPending: Boolean get() = synchronized(lock) { future != null }

    /**
     * Blocks the calling (server) thread until the person decides.
     * @param onPending called with the offer when it becomes the open prompt, and with null when it stops being one
     * @param showPrompt raise the out-of-app prompt (a notification); called at most once at a time per background stretch
     * @param clearPrompt take it down again
     */
    fun ask(
        offer: IncomingOffer,
        isVisible: () -> Boolean,
        onPending: (IncomingOffer?) -> Unit,
        showPrompt: (id: Long) -> Unit,
        clearPrompt: () -> Unit,
    ): ConsentDecision {
        val address = offer.senderAddress
        val mine = CompletableFuture<ConsentDecision>()
        val id: Long
        synchronized(lock) {
            val until = coolOff[address]
            if (until != null && clock() < until) return ConsentDecision.DECLINE
            if (future != null) return ConsentDecision.DECLINE
            future = mine; id = ++seq; currentId = id
            onPending(offer)
        }
        var decision = ConsentDecision.DECLINE
        var shownAt = -1L
        try {
            while (true) {
                val background = !isVisible()
                if (background && shownAt < 0) { shownAt = clock(); showPrompt(id) }
                else if (!background && shownAt >= 0) { shownAt = -1; clearPrompt() }
                if (background && clock() - shownAt >= backgroundTimeoutMs) break        // nobody answered: the safe answer is no
                try { decision = mine.get(pollMs, TimeUnit.MILLISECONDS); break } catch (e: TimeoutException) { /* poll again */ }
            }
        } catch (e: InterruptedException) { Thread.currentThread().interrupt()           // the server is stopping
        } catch (e: Exception) { decision = ConsentDecision.DECLINE }
        finally {
            synchronized(lock) {
                if (future === mine) { future = null; currentId = 0; onPending(null); clearPrompt() }
                if (decision != ConsentDecision.ACCEPT) {
                    val now = clock()
                    if (coolOff.size > 256) coolOff.entries.removeIf { it.value <= now }
                    if (coolOff.size > 256) coolOff.clear()
                    coolOff[address] = now + coolOffMs
                }
            }
        }
        return decision
    }

    /** Answer the open prompt. With [id], only if that is still the prompt being shown. Returns whether it applied. */
    fun resolve(decision: ConsentDecision, id: Long? = null): Boolean = synchronized(lock) {
        val f = future ?: return false
        if (id != null && id != currentId) return false
        f.complete(decision)
    }
}
