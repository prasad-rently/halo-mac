package app.halo.mobile

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * TEMPORARY STUB — NOT the real contract. The android-tools workstream (origin/feat/v2.6-m-android-tools) defines the hub in
 * package `app.halo.mobile.tools`: `data class Tool(id, title, subtitle, icon, content)` and `ToolsRegistry.tools`, one
 * `Tool("...") { ... }` line per entry. This file's `ToolEntry` / `entries` are a different shape. At merge: DELETE this file,
 * ToolsLauncherStub.kt, the `ToolsLauncherStub()` call in SettingsScreen and `SimilarPhotosTool`, and add one line to the real
 * registry: `Tool("photos", "Similar photos", "Near-duplicate pictures", Icons.Filled.Star) { SimilarPhotosScreen() }`.
 */
data class ToolEntry(val id: String, val title: String, val icon: ImageVector?, val content: @Composable () -> Unit)

object ToolsRegistry {
    val entries: List<ToolEntry> = listOf(
        app.halo.mobile.photos.SimilarPhotosTool.entry,   // F-025 Similar Photos
    )
}
