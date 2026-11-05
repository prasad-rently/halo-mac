package app.halo.mobile.tools

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.halo.mobile.Halo

/*
 * LOCAL SHIM. The mobile design system (HaloCard / HaloMetricTile / HaloListRow / HaloChip / HaloPrimaryButton /
 * HaloIconButton / HaloEmptyState / HaloInfoSheet) is being built on feat/v2.6-m-android-design. These have the same names
 * and the same job so that, when that branch lands, deleting this file and changing the imports is the whole migration.
 * Tokens are the desktop's (docs/DESIGN_SYSTEM.md); nothing here invents a new one.
 */

val HaloAccent2 = Color(0xFF7B5EA7)

@Composable
fun HaloChip(label: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    FilterChip(selected = selected, onClick = onClick, enabled = enabled, modifier = modifier, label = { Text(label, fontSize = 13.sp, maxLines = 1) },
        colors = FilterChipDefaults.filterChipColors(selectedContainerColor = Halo.Accent.copy(alpha = 0.22f), selectedLabelColor = Halo.Accent, containerColor = Halo.Surface2, labelColor = Halo.Text2),
        border = FilterChipDefaults.filterChipBorder(enabled = enabled, selected = selected, borderColor = Halo.Border, selectedBorderColor = Halo.Accent.copy(alpha = 0.6f)))
}

@Composable
fun HaloPrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val shape = RoundedCornerShape(12.dp)
    Box(modifier.defaultMinSize(minHeight = 48.dp).clip(shape)
        .background(if (enabled) Brush.horizontalGradient(listOf(Halo.Accent, HaloAccent2)) else Brush.horizontalGradient(listOf(Halo.Surface2, Halo.Surface2)))
        .clickable(enabled = enabled, role = Role.Button, onClick = onClick).padding(horizontal = 20.dp), contentAlignment = Alignment.Center) {
        Text(text, color = if (enabled) Color.White else Halo.Text3, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** A 48dp icon button; [description] is the TalkBack label, so it is required. */
@Composable
fun HaloIconButton(icon: ImageVector, description: String, onClick: () -> Unit, modifier: Modifier = Modifier, tint: Color = Halo.Text2) {
    IconButton(onClick = onClick, modifier = modifier.size(48.dp)) { Icon(icon, contentDescription = description, tint = tint) }
}

@Composable
fun HaloMetricTile(label: String, value: String?, unit: String, modifier: Modifier = Modifier, accent: Color = Halo.Text) {
    Column(modifier.clip(RoundedCornerShape(14.dp)).background(Halo.Surface).padding(14.dp)) {
        Text(label.uppercase(), color = Halo.Text3, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp)
        Spacer(Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value ?: "—", color = if (value == null) Halo.Text3 else accent, fontSize = 28.sp, fontWeight = FontWeight.Bold, maxLines = 1)
            if (value != null) Text(" $unit", color = Halo.Text2, fontSize = 12.sp, modifier = Modifier.padding(bottom = 5.dp))
        }
    }
}

@Composable
fun HaloListRow(title: String, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    Text(title, color = Halo.Text, fontSize = 13.sp, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
        modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(Halo.Surface2).let { if (onClick != null) it.clickable(onClick = onClick) else it }.defaultMinSize(minHeight = 48.dp).padding(horizontal = 12.dp, vertical = 14.dp))
}

@Composable
fun HaloEmptyState(icon: ImageVector, line: String, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(vertical = 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, contentDescription = null, tint = Halo.Text3, modifier = Modifier.size(28.dp)); Spacer(Modifier.height(6.dp))
        Text(line, color = Halo.Text3, fontSize = 13.sp)
    }
}

/** Where every explanation lives: primary screens carry no paragraphs, the (i) button opens this. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HaloInfoSheet(title: String, onDismiss: () -> Unit, content: @Composable () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Halo.Surface) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, color = Halo.Text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            content()
        }
    }
}

@Composable
fun InfoLine(text: String) = Text(text, color = Halo.Text2, fontSize = 13.sp)

/** Small status pill: green = fine, amber = heads-up, red = problem. */
@Composable
fun HaloStatusChip(text: String, color: Color, modifier: Modifier = Modifier) {
    Text(text, color = color, fontSize = 12.sp, fontWeight = FontWeight.Medium,
        modifier = modifier.clip(RoundedCornerShape(50)).background(color.copy(alpha = 0.14f)).padding(horizontal = 10.dp, vertical = 5.dp))
}
