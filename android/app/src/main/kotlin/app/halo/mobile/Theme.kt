package app.halo.mobile

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import app.halo.mobile.design.HaloColors

// Compatibility layer. The design system lives in app.halo.mobile.design (see android/DESIGN.md); these names are kept so
// code written against the old Theme.kt (and branches that have not rebased yet) keeps compiling. New code should use
// the design package directly.
object Halo {
    val Background = HaloColors.Background; val Surface = HaloColors.Surface; val Surface2 = HaloColors.Surface2
    val Accent = HaloColors.Accent; val Green = HaloColors.Green; val Amber = HaloColors.Amber; val Red = HaloColors.Red
    val Cyan = HaloColors.Cyan; val Purple = HaloColors.Purple
    val Text = HaloColors.Text; val Text2 = HaloColors.Text2; val Text3 = HaloColors.Text3
    val Border = HaloColors.Border
}

@Composable
fun HaloTheme(content: @Composable () -> Unit) = app.halo.mobile.design.HaloTheme(content)

@Composable
fun HaloCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) =
    app.halo.mobile.design.HaloCard(modifier, content = content)

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) =
    androidx.compose.material3.Text(text.uppercase(), modifier = modifier, style = app.halo.mobile.design.HaloType.Label, color = HaloColors.Text2)

fun formatBytes(n: Long): String = when {
    n < 1024 -> "$n B"
    n < 1024 * 1024 -> "%.1f KB".format(n / 1024.0)
    n < 1024L * 1024 * 1024 -> "%.1f MB".format(n / 1048576.0)
    else -> "%.2f GB".format(n / 1073741824.0)
}
