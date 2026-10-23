package app.halo.mobile

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Halo's dark-only design tokens (docs/DESIGN_SYSTEM.md), mirrored for Android. Dark-only by design.
object Halo {
    val Background = Color(0xFF080C14); val Surface = Color(0xFF0D1220); val Surface2 = Color(0xFF131928)
    val Accent = Color(0xFF4F7CFF); val Green = Color(0xFF22D97A); val Amber = Color(0xFFF5A623); val Red = Color(0xFFFF4D6A)
    val Text = Color(0xFFEEF2FB); val Text2 = Color(0xFFA9B4CC); val Text3 = Color(0xFF6B7791)
    val Border = Color(0x14FFFFFF)
}

@Composable
fun HaloTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Halo.Accent, onPrimary = Color.White, background = Halo.Background, onBackground = Halo.Text,
            surface = Halo.Surface, onSurface = Halo.Text, surfaceVariant = Halo.Surface2, onSurfaceVariant = Halo.Text2,
            error = Halo.Red, outline = Halo.Border,
        ),
        content = content,
    )
}

@Composable
fun HaloCard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = Halo.Surface),
    ) { Column(Modifier.padding(14.dp)) { content() } }
}

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), modifier = modifier, color = Halo.Text3, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.4.sp)
}

fun formatBytes(n: Long): String = when {
    n < 1024 -> "$n B"
    n < 1024 * 1024 -> "%.1f KB".format(n / 1024.0)
    n < 1024L * 1024 * 1024 -> "%.1f MB".format(n / 1048576.0)
    else -> "%.2f GB".format(n / 1073741824.0)
}
