package app.halo.mobile.background

import android.content.Intent
import android.net.Uri
import androidx.core.content.IntentCompat

/**
 * F-055 FR-B3: what the Sharesheet hands us is untrusted input from another app. The one dangerous shape is a
 * `file://` (or otherwise non-`content://`) URI naming a file in THIS app's private storage — sending it would read
 * the pairing profile or the clipboard history off the phone. So only `content://` URIs are accepted, and they are
 * capped, because the sender is not trusted to be sensible about how many it passes.
 */
object SharedUris {
    const val MAX = 100

    /**
     * Provider authorities that hold data this app can read but the sharing app may not be entitled to. Halo holds
     * READ_SMS, so a hostile app could otherwise name the telephony providers and have Halo read them on its behalf.
     */
    private val sensitiveAuthorities = setOf("sms", "mms", "mms-sms", "telephony", "com.android.contacts", "call_log", "icc")

    /** The pure rule, JVM-testable. [authority] is the URI's authority; [ownPackage] this app's package. */
    fun acceptable(scheme: String?, authority: String?, ownPackage: String = "app.halo.mobile"): Boolean {
        if (!"content".equals(scheme, ignoreCase = true)) return false          // file://, android.resource://, http://, … all refused
        // `content://<userId>@<authority>/…` addresses the same provider (ContentProvider strips the user id), so a bare
        // startsWith on the raw authority would let `content://0@app.halo.mobile.x/…` straight past the own-package check.
        val a = authority?.substringAfterLast('@')?.lowercase()?.takeIf { it.isNotEmpty() } ?: return false
        if (a.startsWith(ownPackage.lowercase())) return false                    // never one of our own providers
        return a !in sensitiveAuthorities
    }

    fun extract(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        val raw: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE -> IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> emptyList()
        }
        return raw.filter { acceptable(it.scheme, it.authority) }.take(MAX)
    }
}
