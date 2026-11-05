package app.halo.mobile

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * MINIMAL STUB of the Tools registry owned by the android-tools workstream. It is here only so Similar Photos can register
 * itself without creating a competing hub; the signatures are exactly the agreed contract, so merging the two branches is a
 * union of the entries list. If android-tools' ToolsRegistry.kt is present at merge, TAKE THEIRS and keep the single
 * `SimilarPhotosTool.entry` line in `entries`.
 */
data class ToolEntry(val id: String, val title: String, val icon: ImageVector?, val content: @Composable () -> Unit)

object ToolsRegistry {
    val entries: List<ToolEntry> = listOf(
        app.halo.mobile.photos.SimilarPhotosTool.entry,   // F-025 Similar Photos
    )
}
