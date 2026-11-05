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
    @RequiresApi(Build.VERSION_CODES.R)
    fun intentSender(resolver: ContentResolver, confirmed: ConfirmedDeletion): IntentSender {
        val uris: List<Uri> = confirmed.plan.items.map { Uri.parse(it.uri) }
        return MediaStore.createTrashRequest(resolver, uris, true).intentSender
    }
}
