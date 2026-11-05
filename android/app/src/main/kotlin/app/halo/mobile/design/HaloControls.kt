package app.halo.mobile.design

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The one big call-to-action per screen/card: accent→accent2 gradient, white label, >=48dp tall, haptic tick on press.
 * Disabled = flat surface with muted label (never just a lower alpha of the gradient, which still reads as tappable).
 */
@Composable
fun HaloPrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    loading: Boolean = false,
    enabled: Boolean = true,
) {
    val haptic = LocalHapticFeedback.current
    val active = enabled && !loading
    Row(
        modifier.defaultMinSize(minHeight = HaloSpacing.MinTouch).clip(HaloShapes.Button)
            .background(if (active) HaloColors.AccentGradient else androidx.compose.ui.graphics.SolidColor(HaloColors.Surface))
            .let { if (active) it else it.border(1.dp, HaloColors.Border, HaloShapes.Button) }
            .clickable(enabled = active, role = Role.Button) { haptic.performHapticFeedback(HapticFeedbackType.ContextClick); onClick() }
            .padding(horizontal = 18.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        val fg = if (active) Color.White else HaloColors.Text3
        if (loading) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Color.White)
        else if (icon != null) Icon(icon, null, Modifier.size(18.dp), tint = fg)
        if (loading || icon != null) Spacer(Modifier.width(8.dp))
        Text(text, color = fg, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** Secondary action — desktop's HaloGhostButton: transparent, hairline border, text2 label. */
@Composable
fun HaloGhostButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, enabled: Boolean = true, tint: Color = HaloColors.Text2) {
    Row(
        modifier.defaultMinSize(minHeight = HaloSpacing.MinTouch).clip(HaloShapes.Button).border(BorderStroke(1.dp, HaloColors.Border2), HaloShapes.Button)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick).alpha(if (enabled) 1f else 0.45f).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { Icon(icon, null, Modifier.size(16.dp), tint = tint); Spacer(Modifier.width(6.dp)) }
        Text(text, color = tint, fontSize = 13.sp, fontWeight = FontWeight.Medium)
    }
}

/** Round icon-only button, 48dp target. [description] is required: it is the TalkBack label. */
@Composable
fun HaloIconButton(icon: ImageVector, description: String, onClick: () -> Unit, modifier: Modifier = Modifier, tint: Color = HaloColors.Text2, filled: Boolean = false, enabled: Boolean = true) {
    Box(
        modifier.size(HaloSpacing.MinTouch).clip(CircleShape).let { if (filled) it.background(tint.copy(alpha = 0.15f)) else it }
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick).alpha(if (enabled) 1f else 0.4f).semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = tint, modifier = Modifier.size(22.dp)) }
}

/** Pill chip: filter/selector ([selected] shows the accent) or a one-tap action (OTP "Copy 123456"). */
@Composable
fun HaloChip(
    text: String,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    tint: Color = HaloColors.Accent,
    icon: ImageVector? = null,
    onClick: (() -> Unit)? = null,
) {
    val bg = if (selected) tint.copy(alpha = 0.18f) else HaloColors.Surface
    val border = if (selected) tint.copy(alpha = 0.6f) else HaloColors.Border2
    val fg = if (selected) tint else HaloColors.Text2
    Row(
        modifier.defaultMinSize(minHeight = 36.dp).clip(HaloShapes.Chip).background(bg).border(1.dp, border, HaloShapes.Chip)
            .let { if (onClick != null) it.clickable(role = Role.Button, onClick = onClick) else it }
            .semantics { this.selected = selected }.padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { Icon(icon, null, Modifier.size(14.dp), tint = fg); Spacer(Modifier.width(6.dp)) }
        Text(text, color = fg, fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

/** Small state pill: the honest-limit / health tag ("Viewer only", "Synced", "Needs permission"). Colour carries meaning, the word carries it too. */
@Composable
fun HaloStatusBadge(text: String, color: Color, modifier: Modifier = Modifier, icon: ImageVector? = null) {
    Row(modifier.clip(HaloShapes.Chip).background(color.copy(alpha = 0.15f)).padding(horizontal = 9.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Icon(icon, null, Modifier.size(12.dp), tint = color); Spacer(Modifier.width(4.dp)) }
        Text(text, color = color, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** Switch styled like desktop's HaloToggle: green when on. Keep the row (title + switch) as the tap target via [HaloToggleRow]. */
@Composable
fun HaloSwitch(checked: Boolean, onCheckedChange: ((Boolean) -> Unit)?, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Switch(checked, onCheckedChange, modifier, enabled = enabled, colors = SwitchDefaults.colors(
        checkedThumbColor = Color.White, checkedTrackColor = HaloColors.Green, checkedBorderColor = HaloColors.Green,
        uncheckedThumbColor = HaloColors.Text2, uncheckedTrackColor = HaloColors.Surface, uncheckedBorderColor = HaloColors.Border2,
        disabledCheckedTrackColor = HaloColors.Green.copy(alpha = 0.4f), disabledUncheckedTrackColor = HaloColors.Surface))
}

@Preview("Buttons")
@Composable
private fun ButtonsPreview() = PreviewSurface {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        HaloPrimaryButton("Send clipboard", {}, icon = Icons.Filled.Send)
        HaloPrimaryButton("Syncing", {}, loading = true)
        HaloPrimaryButton("Disabled", {}, enabled = false)
        HaloGhostButton("Retry skipped", {}, icon = Icons.Filled.Refresh)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { HaloIconButton(Icons.Filled.Check, "Copy", {}, filled = true, tint = HaloColors.Accent); HaloIconButton(Icons.Filled.Send, "Send", {}) }
    }
}

@Preview("Chips + badges")
@Composable
private fun ChipsPreview() = PreviewSurface {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { HaloChip("All", selected = true, onClick = {}); HaloChip("SIM 1", onClick = {}); HaloChip("Copy 482913", tint = HaloColors.Green, icon = Icons.Filled.Check, onClick = {}) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { HaloStatusBadge("Synced", HaloColors.Green, icon = Icons.Filled.Check); HaloStatusBadge("Needs permission", HaloColors.Amber, icon = Icons.Filled.Warning); HaloStatusBadge("Error", HaloColors.Red) }
        Row(verticalAlignment = Alignment.CenterVertically) { HaloSwitch(true, {}); Spacer(Modifier.width(8.dp)); HaloSwitch(false, {}) }
    }
}
