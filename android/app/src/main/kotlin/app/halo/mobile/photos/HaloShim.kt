@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package app.halo.mobile.photos

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.halo.mobile.Halo

/*
 * LOCAL SHIM — same component names and shapes as the android-design workstream's design system
 * (HaloMetricTile / HaloChip / HaloPrimaryButton / HaloIconButton / HaloEmptyState / HaloInfoSheet / HaloRing;
 * HaloCard already exists in Theme.kt). Lives in this package so it cannot collide with app.halo.mobile.design.
 * When origin/feat/v2.6-m-android-design lands: delete this file and swap the imports in SimilarPhotosScreen.kt.
 */

@Composable
fun HaloMetricTile(label: String, value: String, modifier: Modifier = Modifier, accent: Color = Halo.Text) {
    Column(modifier.background(Halo.Surface2, RoundedCornerShape(12.dp)).padding(12.dp).semantics(mergeDescendants = true) { contentDescription = "$label: $value" }) {
        Text(value, color = accent, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Text(label.uppercase(), color = Halo.Text3, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp)
    }
}

@Composable
fun HaloChip(label: String, selected: Boolean = false, accent: Color = Halo.Accent, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val shape = RoundedCornerShape(50)
    val base = modifier.defaultMinSize(minHeight = 40.dp)
        .background(if (selected) accent.copy(alpha = 0.18f) else Halo.Surface2, shape)
        .let { if (onClick != null) it.clickable(onClick = onClick) else it }
        .padding(horizontal = 14.dp)
    Box(base, contentAlignment = Alignment.Center) { Text(label, color = if (selected) accent else Halo.Text2, fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
}

@Composable
fun HaloPrimaryButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, destructive: Boolean = false) {
    val brush = if (destructive) Brush.horizontalGradient(listOf(Halo.Red, Halo.Red.copy(alpha = 0.8f))) else Brush.horizontalGradient(listOf(Halo.Accent, Color(0xFF7B5EA7)))
    Button(
        onClick = onClick, enabled = enabled, modifier = modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(16.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, disabledContainerColor = Color.Transparent),
    ) {
        Box(Modifier.fillMaxWidth().height(56.dp).background(if (enabled) brush else Brush.horizontalGradient(listOf(Halo.Surface2, Halo.Surface2)), RoundedCornerShape(16.dp)), contentAlignment = Alignment.Center) {
            Text(label, color = if (enabled) Color.White else Halo.Text3, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
fun HaloIconButton(icon: ImageVector, description: String, onClick: () -> Unit, modifier: Modifier = Modifier, tint: Color = Halo.Text2) {
    IconButton(onClick = onClick, modifier = modifier.size(48.dp)) { Icon(icon, description, tint = tint) }
}

@Composable
fun HaloEmptyState(title: String, action: String?, onAction: (() -> Unit)?, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(vertical = 20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, color = Halo.Text2, fontSize = 15.sp, fontWeight = FontWeight.Medium)
        if (action != null && onAction != null) HaloPrimaryButton(action, onAction)
    }
}

@Composable
fun HaloRing(progress: Float, centre: String, modifier: Modifier = Modifier, color: Color = Halo.Accent, size: androidx.compose.ui.unit.Dp = 84.dp) {
    Box(modifier.size(size).semantics { contentDescription = "$centre" }, contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size)) {
            val w = 9.dp.toPx(); val inset = w / 2
            drawArc(Halo.Surface2, 0f, 360f, false, Offset(inset, inset), Size(this.size.width - w, this.size.height - w), style = Stroke(w))
            drawArc(color, -90f, 360f * progress.coerceIn(0f, 1f), false, Offset(inset, inset), Size(this.size.width - w, this.size.height - w), style = Stroke(w, cap = StrokeCap.Round))
        }
        Text(centre, color = Halo.Text, fontSize = 16.sp, fontWeight = FontWeight.Bold)
    }
}

/** Explanations live here, not on the main surface. */
@Composable
fun HaloInfoSheet(title: String, lines: List<String>, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Halo.Surface) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, color = Halo.Text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            lines.forEach { Text(it, color = Halo.Text2, fontSize = 14.sp) }
            Spacer(Modifier.height(4.dp))
        }
    }
}
