package app.halo.mobile

import android.Manifest
import android.content.pm.PackageManager
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Home
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.halo.mobile.cloud.CloudViewModel
import app.halo.mobile.cloud.LocalInbox
import app.halo.mobile.design.*
import java.util.Calendar

/** The five bottom-bar destinations. Everything else lives behind Home's quick actions or its "More" list. */
enum class HaloDestination { Home, Messages, Clipboard, Share, Settings }

/** A row in Home's "More" list. Features that don't earn a bottom-bar slot (Tools, Spend, Similar Photos...) add one here. */
data class MoreEntry(val title: String, val subtitle: String, val icon: ImageVector, val tag: String, val onClick: () -> Unit)

@Composable
fun HomeScreen(vm: AppViewModel, cloud: CloudViewModel, go: (HaloDestination) -> Unit, extraMore: List<MoreEntry> = emptyList(), onCheckDatabase: () -> Unit = {}) {
    val identity by vm.identity.collectAsStateWithLifecycle()
    val profile by cloud.profile.collectAsStateWithLifecycle()
    val problem by cloud.profileProblem.collectAsStateWithLifecycle()
    val smsOn by cloud.smsEnabled.collectAsStateWithLifecycle()
    val clipOn by cloud.clipEnabled.collectAsStateWithLifecycle()
    val syncing by cloud.syncing.collectAsStateWithLifecycle()
    val history by cloud.history.collectAsStateWithLifecycle()
    val peers by vm.peers.collectAsStateWithLifecycle()
    val listen by vm.listen.collectAsStateWithLifecycle()
    val inbox by vm.inbox.collectAsStateWithLifecycle()
    val refusal by vm.backgroundRefusal.collectAsStateWithLifecycle()
    val notice by cloud.clipNotice.collectAsStateWithLifecycle()
    val syncNotice by cloud.notice.collectAsStateWithLifecycle()
    cloud.syncTick.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    val prefs = cloud.prefs
    val now = System.currentTimeMillis()

    var todayCount by remember { mutableIntStateOf(-1) }
    fun refreshToday() {
        todayCount = if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED) {
            val midnight = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis
            LocalInbox.recent(ctx, 999, midnight).size
        } else -1
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { refreshToday(); vm.refreshInbox(); if (profile == null && problem != null) cloud.refreshProfile() }
    LaunchedEffect(prefs.lastSyncAt) { refreshToday() }

    val health = cloudHealth(profile != null, problem != null, smsOn, clipOn, syncing, prefs.lastSyncAt, prefs.lastSyncError, prefs.quarantinedCount)
    val (color, headline, ringValue, ringText) = when (health) {
        CloudHealth.OK -> Quad(HaloColors.Green, "Synced", 1f, "OK")
        CloudHealth.SYNCING -> Quad(HaloColors.Accent, "Syncing", 0.5f, "...")
        CloudHealth.WARNING -> Quad(HaloColors.Amber, "Some skipped", 0.75f, "!")
        CloudHealth.ERROR -> Quad(HaloColors.Red, "Sync error", 0.4f, "!")
        CloudHealth.NEVER -> Quad(HaloColors.Accent, "Ready", 0.0f, "-")
        CloudHealth.OFF -> Quad(HaloColors.Text3, "Sync off", 0.0f, "off")
        CloudHealth.NEEDS_ATTENTION -> Quad(HaloColors.Amber, "Needs attention", 0.25f, "!")
        CloudHealth.NOT_PAIRED -> Quad(HaloColors.Text3, "Not connected", 0.0f, "-")
    }
    val lastSync = prefs.lastSyncAt

    HaloScreen(HaloCopy.HOME_TITLE, subtitle = identity.alias) {
        // Status: the cloud ring. One glance = is my phone talking to my Mac?
        HaloCard(accentTop = color) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                HaloRing(ringValue, color = color, size = 96.dp, strokeWidth = 9.dp, description = "Cloud: $headline") {
                    Text(ringText, color = color, style = HaloType.Number)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Cloud: $headline", style = HaloType.Title, color = HaloColors.Text, modifier = Modifier.testTag("home.status"))
                    Text(if (lastSync > 0 && profile != null) "Last sync ${RelativeTime.ago(now, lastSync)}" else if (profile == null) "Pair with your Mac" else "No sync yet", style = HaloType.Caption, color = HaloColors.Text2)
                    if (profile != null) HaloStatusBadge("Encrypted", HaloColors.Green, icon = Icons.Filled.Lock)
                }
            }
            if (profile == null && problem == null) { Spacer(Modifier.height(12.dp)); HaloPrimaryButton(HaloCopy.CONNECT_TO_MAC, { go(HaloDestination.Messages) }, Modifier.fillMaxWidth().testTag("home.connect"), icon = Icons.Filled.Send) }
        }
        // Safety UI stays visible where it matters: a saved connection that can't be opened.
        problem?.let { ProfileProblemCard(cloud, it) }
        refusal?.let { HaloBanner("Background receiving is off: notifications are hidden.", info = HaloCopy.INFO_NOTIFICATION_GATE, actionLabel = "Open Settings", onAction = { go(HaloDestination.Settings) }, actionTag = Modifier.testTag("home.refusal.open")) }
        if (prefs.quarantinedCount > 0 && profile != null) {
            val n = prefs.quarantinedCount
            HaloBanner(if (n == 1) "1 message couldn't be synced" else "$n messages couldn't be synced", actionLabel = HaloCopy.RETRY_SKIPPED, onAction = { cloud.retrySkipped() }, actionTag = Modifier.testTag("home.retrySkipped"))
        }

        // 2x2 metric tiles
        Row(Modifier.height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            HaloMetricTile(HaloCopy.TILE_MESSAGES, if (todayCount >= 0) "$todayCount" else "-", Icons.Filled.Email, Modifier.weight(1f).fillMaxHeight(), HaloColors.Accent, onClick = { go(HaloDestination.Messages) })
            HaloMetricTile(HaloCopy.TILE_CLIPBOARD, "${history.size}", Icons.Filled.Send, Modifier.weight(1f).fillMaxHeight(), HaloColors.Cyan, onClick = { go(HaloDestination.Clipboard) })
        }
        Row(Modifier.height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val ready = listen is ListenState.Listening
            HaloMetricTile(HaloCopy.TILE_NEARBY, "${peers.size}", Icons.Filled.Share, Modifier.weight(1f).fillMaxHeight(), if (ready) HaloColors.Green else HaloColors.Amber,
                caption = if (ready) "Ready to receive" else "Not listening", onClick = { go(HaloDestination.Share) })
            HaloMetricTile(HaloCopy.TILE_LAST_SYNC, if (lastSync > 0) RelativeTime.compact(now, lastSync) else "-", Icons.Filled.Refresh, Modifier.weight(1f).fillMaxHeight(), HaloColors.Accent2.lighten(),
                onClick = { cloud.syncNow(reconcile = false) })
        }

        // Quick actions
        HaloSectionHeader(HaloCopy.QUICK_ACTIONS)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            QuickAction(HaloCopy.QA_SEND_CLIPBOARD, Icons.Filled.Send, "home.sendClipboard") { if (clipOn) cloud.sendClipboardNow() else go(HaloDestination.Clipboard) }
            QuickAction(HaloCopy.QA_SEND_FILE, Icons.Filled.Share, "home.sendFile") { go(HaloDestination.Share) }
            QuickAction(HaloCopy.QA_SCAN, Icons.Filled.Search, "home.scan") { vm.scan(); go(HaloDestination.Share) }
            QuickAction(HaloCopy.QA_CHECK, Icons.Filled.Check, "home.check") { if (profile != null) onCheckDatabase() else go(HaloDestination.Messages) }
        }
        (notice ?: syncNotice)?.let { Text(it, style = HaloType.Caption, color = HaloColors.Text2, modifier = Modifier.testTag("home.notice")) }

        // Recent activity (real events only: last sync, clipboard history, received files)
        HaloSectionHeader(HaloCopy.RECENT)
        val rows = remember(history, inbox, lastSync) { recentActivity(history, inbox, lastSync, prefs.lastSyncSummary) }
        if (rows.isEmpty()) HaloCard { HaloEmptyState(Icons.Filled.Home, HaloCopy.NO_ACTIVITY, subtitle = HaloCopy.NO_ACTIVITY_SUB) }
        else HaloCard {
            rows.take(5).forEachIndexed { i, r ->
                HaloListRow(r.title, subtitle = r.subtitle, icon = r.icon, tint = r.tint, trailing = { Text(RelativeTime.compact(now, r.atMs), color = HaloColors.Text3, style = HaloType.Caption) })
            }
        }

        // More: everything that isn't a bottom-bar destination
        val more = listOf(MoreEntry("Received files", "${inbox.size} saved on this phone", Icons.Filled.Share, "home.more.received") { go(HaloDestination.Share) }) + extraMore
        HaloSectionHeader(HaloCopy.MORE)
        HaloCard { more.forEach { HaloListRow(it.title, subtitle = it.subtitle, icon = it.icon, onClick = it.onClick, modifier = Modifier.testTag(it.tag)) } }
    }
}

private data class Quad<A, B, C, D>(val a: A, val b: B, val c: C, val d: D)

private fun Color.lighten(): Color = Color(red + (1 - red) * 0.25f, green + (1 - green) * 0.25f, blue + (1 - blue) * 0.25f, alpha)

@Composable
private fun androidx.compose.foundation.layout.RowScope.QuickAction(label: String, icon: ImageVector, tag: String, onClick: () -> Unit) {
    val modifier = Modifier.weight(1f)
    Column(
        modifier.clip(HaloShapes.Tile).clickable(role = Role.Button, onClick = onClick).padding(vertical = 6.dp).testTag(tag),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(56.dp).clip(HaloShapes.Tile).background(HaloColors.AccentGradient), contentAlignment = Alignment.Center) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(26.dp)) }
        Text(label, color = HaloColors.Text, fontSize = 12.sp, textAlign = TextAlign.Center, maxLines = 2)
    }
}

internal data class ActivityRow(val title: String, val subtitle: String?, val icon: ImageVector, val tint: Color, val atMs: Long)

internal fun recentActivity(history: List<app.halo.mobile.cloud.ClipItem>, inbox: List<InboxItem>, lastSyncAt: Long, lastSummary: String): List<ActivityRow> {
    val rows = ArrayList<ActivityRow>()
    if (lastSyncAt > 0) rows.add(ActivityRow("Messages synced", lastSummary.ifBlank { null }, Icons.Filled.Refresh, HaloColors.Accent, lastSyncAt))
    history.take(5).forEach { rows.add(ActivityRow(if (it.received) "Clipboard from ${it.from}" else "Clipboard sent", it.text.lineSequence().firstOrNull().orEmpty().take(60).ifBlank { null }, Icons.Filled.Send, if (it.kind == "url") HaloColors.Cyan else HaloColors.Accent, it.atMs)) }
    inbox.sortedByDescending { it.modified }.take(3).forEach { rows.add(ActivityRow("File received", it.name, Icons.Filled.Share, HaloColors.Green, it.modified)) }
    return rows.sortedByDescending { it.atMs }
}
