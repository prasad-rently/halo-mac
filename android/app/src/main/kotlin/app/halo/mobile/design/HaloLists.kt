package app.halo.mobile.design

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Screen scaffold content: vertical scroll, 16dp gutters, 12dp rhythm, big title (+ optional one-line subtitle).
 * Use as the root of every top-level screen so titles and spacing are identical everywhere.
 */
@Composable
fun HaloScreen(title: String, modifier: Modifier = Modifier, subtitle: String? = null, trailing: @Composable (() -> Unit)? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = HaloSpacing.ScreenH, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(HaloSpacing.Gap)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, style = HaloType.Display, color = HaloColors.Text, modifier = Modifier.semantics { heading() })
                if (subtitle != null) Text(subtitle, style = HaloType.Caption, color = HaloColors.Text2)
            }
            trailing?.invoke()
        }
        content()
    }
}

/** Small-caps section label with an optional (i) info button and a trailing text action ("See all"). */
@Composable
fun HaloSectionHeader(title: String, modifier: Modifier = Modifier, info: HaloInfo? = null, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
    Row(modifier.fillMaxWidth().defaultMinSize(minHeight = 32.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title.uppercase(), style = HaloType.Label, color = HaloColors.Text2, modifier = Modifier.weight(1f).semantics { heading() })
        if (info != null) HaloInfoButton(info)
        if (actionLabel != null && onAction != null) TextButton(onClick = onAction) { Text(actionLabel, color = HaloColors.Accent, fontSize = 12.sp) }
    }
}

/** One row: tinted icon (or any [leading]), title + one-line subtitle, trailing slot. Tappable when [onClick] is given. */
@Composable
fun HaloListRow(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    icon: ImageVector? = null,
    tint: Color = HaloColors.Accent,
    leading: @Composable (() -> Unit)? = null,
    trailing: @Composable (() -> Unit)? = null,
    onClick: (() -> Unit)? = null,
    maxSubtitleLines: Int = 1,
) {
    Row(
        modifier.fillMaxWidth().defaultMinSize(minHeight = HaloSpacing.MinTouch)
            .let { if (onClick != null) it.clickable(role = Role.Button, onClick = onClick) else it }.padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) { leading(); Spacer(Modifier.width(12.dp)) }
        else if (icon != null) { HaloIconBadge(icon, tint); Spacer(Modifier.width(12.dp)) }
        Column(Modifier.weight(1f)) {
            Text(title, color = HaloColors.Text, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (subtitle != null) Text(subtitle, color = HaloColors.Text2, fontSize = 12.sp, maxLines = maxSubtitleLines, overflow = TextOverflow.Ellipsis)
        }
        if (trailing != null) { Spacer(Modifier.width(8.dp)); trailing() }
    }
}

/** Circle with a one-letter monogram — avatars for threads and devices. */
@Composable
fun HaloAvatar(name: String, modifier: Modifier = Modifier, tint: Color = HaloColors.Accent, size: androidx.compose.ui.unit.Dp = 40.dp) {
    Box(modifier.size(size).clip(CircleShape).background(tint.copy(alpha = 0.18f)), contentAlignment = Alignment.Center) {
        Text(name.trim().take(1).uppercase().ifEmpty { "?" }, color = tint, fontWeight = FontWeight.Bold, fontSize = (size.value * 0.42f).sp)
    }
}

/** Empty / unavailable state: one icon, a title, one short line, at most ONE action. No paragraphs. */
@Composable
fun HaloEmptyState(
    icon: ImageVector,
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    tint: Color = HaloColors.Text3,
) {
    Column(modifier.fillMaxWidth().padding(vertical = 24.dp, horizontal = 16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        HaloIconBadge(icon, tint, size = 56.dp, iconSize = 28.dp)
        Text(title, style = HaloType.Title, color = HaloColors.Text, textAlign = TextAlign.Center)
        if (subtitle != null) Text(subtitle, style = HaloType.Caption, color = HaloColors.Text2, textAlign = TextAlign.Center)
        if (actionLabel != null && onAction != null) { Spacer(Modifier.size(4.dp)); HaloPrimaryButton(actionLabel, onAction) }
    }
}

/**
 * A coloured banner for a problem or a state that needs the user ("Notifications are hidden", "Key unavailable"). Used for the
 * safety UI: the message is short, the long explanation goes in [info]. [action] is the single next step.
 */
@Composable
fun HaloBanner(
    text: String,
    modifier: Modifier = Modifier,
    tint: Color = HaloColors.Amber,
    icon: ImageVector = Icons.Filled.Warning,
    info: HaloInfo? = null,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    actionTag: Modifier = Modifier,
    textModifier: Modifier = Modifier,
) {
    HaloCard(modifier, accentTop = tint) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(icon, null, tint = tint, modifier = Modifier.padding(top = 2.dp).size(18.dp)); Spacer(Modifier.width(10.dp))
            Text(text, color = HaloColors.Text, fontSize = 14.sp, modifier = Modifier.weight(1f).then(textModifier))
            if (info != null) HaloInfoButton(info)
        }
        if (actionLabel != null && onAction != null) { Spacer(Modifier.size(8.dp)); HaloGhostButton(actionLabel, onAction, actionTag, tint = tint) }
    }
}

/** A settings row: title, one-line subtitle, optional (i), switch. The whole row toggles. */
@Composable
fun HaloToggleRow(title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier, subtitle: String? = null, info: HaloInfo? = null, enabled: Boolean = true, switchTag: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().defaultMinSize(minHeight = HaloSpacing.MinTouch), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = HaloColors.Text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            if (subtitle != null) Text(subtitle, color = HaloColors.Text2, fontSize = 12.sp)
        }
        if (info != null) HaloInfoButton(info)
        HaloSwitch(checked, onCheckedChange, switchTag, enabled)
    }
}

/** Title + long explanation, shown in a [HaloInfoSheet] behind an (i). Keeps paragraphs off the primary surface. */
data class HaloInfo(val title: String, val body: String, val extra: List<String> = emptyList())

@Composable
fun HaloInfoButton(info: HaloInfo, modifier: Modifier = Modifier) {
    var open by remember { mutableStateOf(false) }
    HaloIconButton(Icons.Filled.Info, "About: ${info.title}", { open = true }, modifier, tint = HaloColors.Text3)
    if (open) HaloInfoSheet(info) { open = false }
}

/** Bottom sheet for "Learn more" content: title, body paragraphs, a single Got it. Never holds an action that changes data. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HaloInfoSheet(info: HaloInfo, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = HaloColors.Surface, contentColor = HaloColors.Text) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(info.title, style = HaloType.Title, color = HaloColors.Text, modifier = Modifier.semantics { heading() })
            Text(info.body, style = HaloType.Body, color = HaloColors.Text2)
            info.extra.forEach { Text(it, style = HaloType.Body, color = HaloColors.Text2) }
            Spacer(Modifier.size(4.dp))
            HaloPrimaryButton("Got it", onDismiss, Modifier.fillMaxWidth())
        }
    }
}

@Preview("List row + empty")
@Composable
private fun ListsPreview() = PreviewSurface {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HaloSectionHeader("Recent activity", info = HaloInfo("Recent activity", "What Halo did lately."), actionLabel = "See all", onAction = {})
        HaloCard {
            HaloListRow("Clipboard sent", subtitle = "to MacBook Pro", icon = Icons.Filled.Share, trailing = { Text("2m", color = HaloColors.Text3, fontSize = 12.sp) })
            HaloListRow("Anna", subtitle = "Your code is 482913", leading = { HaloAvatar("Anna") }, tint = HaloColors.Accent)
        }
        HaloEmptyState(Icons.Filled.Email, "No messages yet", subtitle = "Turn on sync to see them here.", actionLabel = "Turn on sync", onAction = {})
        HaloBanner("Notifications are hidden", info = HaloInfo("Why", "Halo must show one."), actionLabel = "Open settings", onAction = {})
        HaloCard { HaloToggleRow("Keep receiving", true, {}, subtitle = "Off by default", info = HaloInfo("Battery", "Costs some battery.")) }
    }
}
