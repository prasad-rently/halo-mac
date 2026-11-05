package app.halo.mobile.photos

import android.content.ContentResolver
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import app.halo.photos.ConfirmedDeletion

/**
 * The ONLY deletion path. Accepts a [ConfirmedDeletion] (constructible only after the user confirmed the exact list) and
 * returns an IntentSender for Android's own system dialog: the user confirms AGAIN, in the OS's UI, and the photos go to the
 * gallery Trash (recoverable) — `createTrashRequest`, not `createDeleteRequest`, which is a permanent delete. Nothing here
 * deletes anything by itself; there is no `ContentResolver.delete` anywhere in the photos package.
 */
object TrashRequest {
    /**
     * The request's URI list travels inside a PendingIntent over Binder (1 MB shared transaction limit), so thousands of URIs can
     * throw TransactionTooLargeException. One request therefore carries at most this many photos; the rest stay selected and
     * the user runs "Review" again.
     */
    const val MAX_PER_REQUEST = 500

    /** The photos this request will actually carry: the first [MAX_PER_REQUEST] of the confirmed plan. */
    fun batch(confirmed: ConfirmedDeletion): List<app.halo.photos.PhotoRef> = confirmed.plan.items.take(MAX_PER_REQUEST)

    @RequiresApi(Build.VERSION_CODES.R)
    fun intentSender(resolver: ContentResolver, confirmed: ConfirmedDeletion): IntentSender {
        val uris: List<Uri> = batch(confirmed).map { Uri.parse(it.uri) }
        return MediaStore.createTrashRequest(resolver, uris, true).intentSender
    }
}
