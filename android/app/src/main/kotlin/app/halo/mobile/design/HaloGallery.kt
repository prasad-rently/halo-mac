package app.halo.mobile.design

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Every design-system component on one screen. Debug builds open it with
 * `adb shell am start -n app.halo.mobile/.MainActivity --ez gallery true`; it is how the components are checked on a device
 * (truncation, contrast, font scale) while `@Preview` tooling is not available offline.
 */
@Composable
fun HaloDesignGallery(extra: @Composable () -> Unit = {}) {
    HaloScreen("Design", subtitle = "Halo components", modifier = Modifier.statusBarsPadding()) {
        HaloSectionHeader("Ring + tiles")
        HaloCard(accentTop = HaloColors.Green) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                HaloRing(0.82f, color = HaloColors.Green, description = "Cloud synced") {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) { Text("OK", color = HaloColors.Green, style = HaloType.Number); Text("synced", color = HaloColors.Text2, style = HaloType.Caption) }
                }
                Column { Text("Cloud: Synced", style = HaloType.Title, color = HaloColors.Text); Text("Last sync 2 min ago", style = HaloType.Caption, color = HaloColors.Text2); HaloStatusBadge("Encrypted", HaloColors.Green, icon = Icons.Filled.Check) }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            HaloMetricTile("Messages today", "42", Icons.Filled.Email, Modifier.weight(1f), HaloColors.Accent)
            HaloMetricTile("Clipboard", "7", Icons.Filled.Send, Modifier.weight(1f), HaloColors.Cyan, caption = "Synced")
        }
        HaloCard { Text("Activity", color = HaloColors.Text2, style = HaloType.Caption); HaloSparkline(listOf(3f, 5f, 2f, 8f, 6f, 9f, 4f, 10f)) }
        HaloSectionHeader("Buttons + chips", info = HaloInfo("Buttons", "One primary action per screen."))
        HaloPrimaryButton("Send clipboard", {}, icon = Icons.Filled.Send)
        HaloPrimaryButton("Disabled", {}, enabled = false)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            HaloGhostButton("Retry", {}, icon = Icons.Filled.Refresh); HaloIconButton(Icons.Filled.Share, "Share", {}, filled = true, tint = HaloColors.Accent)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { HaloChip("All", selected = true, onClick = {}); HaloChip("SIM 1", onClick = {}); HaloChip("Copy 482913", tint = HaloColors.Green, icon = Icons.Filled.Check, onClick = {}) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { HaloStatusBadge("Synced", HaloColors.Green); HaloStatusBadge("Needs permission", HaloColors.Amber, icon = Icons.Filled.Warning); HaloStatusBadge("Error", HaloColors.Red) }
        HaloSectionHeader("Rows + states")
        HaloCard {
            HaloListRow("Clipboard sent", subtitle = "to MacBook Pro", icon = Icons.Filled.Share)
            HaloListRow("Anna", subtitle = "Your code is 482913", leading = { HaloAvatar("Anna") })
            HaloToggleRow("Keep receiving", true, {}, subtitle = "Off by default", info = HaloInfo("Battery", "Costs some battery."))
        }
        HaloBanner("Notifications are hidden", info = HaloInfo("Why", "Halo must show one while it listens."), actionLabel = "Open settings", onAction = {})
        HaloCard { HaloEmptyState(Icons.Filled.Email, "No messages yet", subtitle = "Turn on sync to see them here.", actionLabel = "Turn on sync", onAction = {}) }
        extra()
        Spacer(Modifier.height(8.dp))
    }
}
