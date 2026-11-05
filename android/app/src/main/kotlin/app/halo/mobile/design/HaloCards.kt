package app.halo.mobile.design

import android.provider.Settings
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** True when the user turned animations off (Developer options / "Remove animations"). Animated components then jump to their end state. */
@Composable
fun rememberReduceMotion(): Boolean {
    val ctx = LocalContext.current
    return remember { runCatching { Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }.getOrDefault(false) }
}

/**
 * Surface card — desktop's HaloCard: surface2 fill, 14dp corners, 1dp hairline border, optional 3dp accent bar across the top
 * (state colour). Pass [onClick] to make the whole card a button.
 */
@Composable
fun HaloCard(
    modifier: Modifier = Modifier,
    accentTop: Color? = null,
    onClick: (() -> Unit)? = null,
    borderColor: Color = HaloColors.Border,
    contentPadding: PaddingValues = PaddingValues(HaloSpacing.CardPad),
    content: @Composable ColumnScope.() -> Unit,
) {
    val base = modifier.fillMaxWidth().clip(HaloShapes.Card).background(HaloColors.Surface2).border(BorderStroke(1.dp, borderColor), HaloShapes.Card)
        .let { if (onClick != null) it.clickable(role = Role.Button, onClick = onClick) else it }
    Box(base) {
        Column(Modifier.padding(contentPadding), content = content)
        if (accentTop != null) Box(Modifier.fillMaxWidth().height(3.dp).background(Brush.horizontalGradient(listOf(accentTop, accentTop.copy(alpha = 0.15f)))))
    }
}

/** A tinted round icon container — the leading visual of metric tiles and list rows. */
@Composable
fun HaloIconBadge(icon: ImageVector, tint: Color, modifier: Modifier = Modifier, size: Dp = 36.dp, iconSize: Dp = 20.dp) {
    Box(modifier.size(size).clip(CircleShape).background(tint.copy(alpha = 0.15f)), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(iconSize))
    }
}

/**
 * Glanceable number tile: icon + big value + label (+ optional caption). Lives in 2x2 grids on Home. The value wraps to a
 * second line rather than truncating, so a key number is never cut off at large font scale.
 */
@Composable
fun HaloMetricTile(
    label: String,
    value: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    tint: Color = HaloColors.Accent,
    caption: String? = null,
    onClick: (() -> Unit)? = null,
) {
    HaloCard(modifier, onClick = onClick) {
        HaloIconBadge(icon, tint, size = 32.dp, iconSize = 18.dp)
        Spacer(Modifier.height(10.dp))
        Text(value, style = HaloType.Number.copy(fontSize = 24.sp), color = HaloColors.Text, maxLines = 2)
        Text(label, style = HaloType.Caption, color = HaloColors.Text2, maxLines = 2)
        if (caption != null) Text(caption, style = HaloType.Caption, color = HaloColors.Text3, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/**
 * Progress ring — desktop's HaloHealthRing / HaloMiniRing. [progress] 0..1 (null = indeterminate-looking empty track).
 * [content] is the centre (usually a big value + a caption). The sweep is a solid state colour, so the round start cap
 * stays one clean colour (desktop's gradient trick, without the seam).
 */
@Composable
fun HaloRing(
    progress: Float?,
    modifier: Modifier = Modifier,
    color: Color = HaloColors.Green,
    size: Dp = 120.dp,
    strokeWidth: Dp = 10.dp,
    description: String? = null,
    content: @Composable BoxScope.() -> Unit = {},
) {
    val reduce = rememberReduceMotion()
    val target = (progress ?: 0f).coerceIn(0f, 1f)
    var start by remember { mutableFloatStateOf(if (reduce) target else 0f) }
    LaunchedEffect(target) { start = target }
    val shown by animateFloatAsState(start, tween(if (reduce) 0 else 700), label = "ring")
    Box(modifier.size(size).let { if (description != null) it.semantics { contentDescription = description } else it }, contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size)) {
            val sw = strokeWidth.toPx()
            val inset = sw / 2
            val arcSize = Size(this.size.width - sw, this.size.height - sw)
            drawArc(Color.White.copy(alpha = 0.07f), 0f, 360f, false, Offset(inset, inset), arcSize, style = Stroke(sw))
            if (shown > 0f) drawArc(color, -90f, 360f * shown, false, Offset(inset, inset), arcSize, style = Stroke(sw, cap = StrokeCap.Round))
        }
        content()
    }
}

/**
 * Bar sparkline — desktop's HaloSparkline: equal-width bars scaled to the series maximum, the latest bar at full strength.
 * Pure decoration for a trend the surrounding text already states, so it carries no accessibility node of its own.
 */
@Composable
fun HaloSparkline(values: List<Float>, modifier: Modifier = Modifier, color: Color = HaloColors.Accent, height: Dp = 36.dp) {
    Canvas(modifier.fillMaxWidth().height(height)) {
        if (values.isEmpty()) return@Canvas
        val max = (values.maxOrNull() ?: 1f).takeIf { it > 0f } ?: 1f
        val gap = 3.dp.toPx()
        val w = ((size.width - gap * (values.size - 1)) / values.size).coerceAtLeast(1f)
        values.forEachIndexed { i, v ->
            val h = (v / max).coerceIn(0.06f, 1f) * size.height
            drawRoundRect(color.copy(alpha = if (i == values.lastIndex) 1f else 0.45f), Offset(i * (w + gap), size.height - h), Size(w, h),
                androidx.compose.ui.geometry.CornerRadius(w / 3, w / 3))
        }
    }
}

@Preview("Card + tiles")
@Composable
private fun CardsPreview() = PreviewSurface {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HaloCard(accentTop = HaloColors.Green) { Text("A card with a state bar", color = HaloColors.Text, style = HaloType.Title) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            HaloMetricTile("Messages today", "42", Icons.Filled.Email, Modifier.weight(1f), HaloColors.Accent)
            HaloMetricTile("Clipboard", "7", Icons.Filled.Send, Modifier.weight(1f), HaloColors.Cyan, caption = "Synced")
        }
    }
}

@Preview("Ring")
@Composable
private fun RingPreview() = PreviewSurface {
    HaloRing(0.82f, color = HaloColors.Green, description = "Cloud synced") {
        Column(horizontalAlignment = Alignment.CenterHorizontally) { Text("OK", color = HaloColors.Green, style = HaloType.Number); Text("synced", color = HaloColors.Text2, style = HaloType.Caption) }
    }
}

@Preview("Sparkline")
@Composable
private fun SparklinePreview() = PreviewSurface { HaloCard { HaloSparkline(listOf(3f, 5f, 2f, 8f, 6f, 9f, 4f, 10f), color = HaloColors.Accent) } }
