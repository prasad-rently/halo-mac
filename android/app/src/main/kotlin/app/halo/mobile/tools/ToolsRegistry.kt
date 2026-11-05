package app.halo.mobile.tools

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * One entry in the Tools hub. This list is the ONLY thing another tool has to touch to appear in the hub — add one line:
 *
 *     Tool("photos", "Similar photos", "Find near-duplicate pictures", Icons.Filled.Star) { SimilarPhotosScreen() }
 *
 * [content] is drawn below the hub's back bar when the tool is open; fetch whatever it needs itself
 * (`viewModel()`, `LocalContext.current`). Keep [id]s stable — they are the hub's route keys.
 */
data class Tool(val id: String, val title: String, val subtitle: String, val icon: ImageVector, val content: @Composable () -> Unit)

object ToolsRegistry {
    val tools: List<Tool> = listOf(
        Tool("transform", "Transform", "Text utilities", Icons.Filled.Edit) { TransformScreen() },
        Tool("beautifier", "Code Image", "Format and share", Icons.Filled.Build) { CodeBeautifierScreen() },
        Tool("speedtest", "Speed Test", "Down, up, ping", Icons.Filled.PlayArrow) { SpeedTestScreen() },
    )

    fun byId(id: String?): Tool? = tools.firstOrNull { it.id == id }
}
