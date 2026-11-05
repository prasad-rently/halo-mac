package app.halo.mobile.tools

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import app.halo.mobile.cloud.ClipItem
import app.halo.mobile.cloud.ClipboardController
import app.halo.mobile.cloud.CloudPrefs

/**
 * The only places the Tools hub touches the clipboard, each reached from a button the person pressed:
 *  - [read] — the Paste buttons. Never called from a lifecycle callback or a LaunchedEffect: Android 10+ blocks background
 *    clipboard reads anyway, and Halo wouldn't want to peek at what you copied in another app just because a screen opened.
 *  - [copy] — Copy buttons. A sensitive result (a generated password) is flagged so Android 13+ hides it from the
 *    clipboard preview and keyboard suggestions.
 *  - [sendToMac] — the same upload path as "Send clipboard now" / the share sheet, subject to the same switch and the secret filter.
 */
internal object ToolsClipboard {
    fun read(ctx: Context): String? = ClipboardController.readClipboard(ctx)

    fun copy(ctx: Context, text: String, sensitive: Boolean) {
        if (!sensitive) {
            // Goes through the controller so Halo's own clipboard listener doesn't publish it straight back (echo suppression).
            ClipboardController.copyToClipboard(ctx, ClipItem("tool-" + System.nanoTime(), text, "text", "This phone", System.currentTimeMillis(), received = false))
            return
        }
        val clip = ClipData.newPlainText("Halo", text)
        if (Build.VERSION.SDK_INT >= 33) clip.description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
        ctx.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
    }

    /** [done] is invoked on the main thread with a content-free outcome ("Sent to your Mac."). */
    fun sendToMac(ctx: Context, text: String, done: (String) -> Unit) {
        val app = ctx.applicationContext
        if (!CloudPrefs(app).clipboardEnabled) { done("Clipboard sync is off — turn it on in the Clipboard tab to send to your Mac."); return }
        val main = Handler(Looper.getMainLooper())
        ClipboardController.publishText(app, text) { msg -> main.post { done(msg) } }
    }
}
