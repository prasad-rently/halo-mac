package app.halo.mobile

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.halo.mobile.design.*
import app.halo.share.ConsentDecision
import app.halo.share.Peer
import java.text.DateFormat
import java.util.Date

@Composable
fun HaloApp(vm: AppViewModel, cloud: app.halo.mobile.cloud.CloudViewModel) {
    var tab by rememberSaveable { mutableIntStateOf(HaloDestination.Home.ordinal) }
    val dest = HaloDestination.entries[tab.coerceIn(0, HaloDestination.entries.lastIndex)]
    val offer by vm.pendingOffer.collectAsStateWithLifecycle()
    val inbox by vm.inbox.collectAsStateWithLifecycle()
    val transfer by vm.transfer.collectAsStateWithLifecycle()
    val shared by vm.shared.collectAsStateWithLifecycle()
    fun go(d: HaloDestination) { tab = d.ordinal; if (d == HaloDestination.Share) vm.refreshInbox() }

    // MR-OS-3: keep the screen (and so the connection) awake for the length of a transfer.
    val view = LocalView.current
    view.keepScreenOn = transfer.isBusy || offer != null

    // Five destinations (Material guidance: 3-5). Tools and everything else that doesn't earn a slot lives under Home -> More.
    Scaffold(
        containerColor = HaloColors.Background,
        bottomBar = {
            NavigationBar(containerColor = HaloColors.Surface) {
                val colors = NavigationBarItemDefaults.colors(selectedIconColor = HaloColors.Accent, selectedTextColor = HaloColors.Accent,
                    indicatorColor = HaloColors.Accent.copy(alpha = 0.16f), unselectedIconColor = HaloColors.Text2, unselectedTextColor = HaloColors.Text2)
                NavItem(dest == HaloDestination.Home, { go(HaloDestination.Home) }, colors, HaloCopy.TAB_HOME, Icons.Filled.Home, "tab.home")
                NavItem(dest == HaloDestination.Messages, { go(HaloDestination.Messages) }, colors, HaloCopy.TAB_MESSAGES, Icons.Filled.Email, "tab.sms")
                NavItem(dest == HaloDestination.Clipboard, { go(HaloDestination.Clipboard) }, colors, HaloCopy.TAB_CLIPBOARD, Icons.Filled.Send, "tab.clipboard")
                NavItem(dest == HaloDestination.Share, { go(HaloDestination.Share) }, colors, HaloCopy.TAB_SHARE, Icons.Filled.Share, "tab.share")
                NavItem(dest == HaloDestination.Settings, { go(HaloDestination.Settings) }, colors, HaloCopy.TAB_SETTINGS, Icons.Filled.Settings, "tab.settings")
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when (dest) {
                HaloDestination.Home -> HomeScreen(vm, cloud, ::go)
                HaloDestination.Messages -> SmsScreen(cloud)
                HaloDestination.Clipboard -> ClipboardScreen(cloud)
                HaloDestination.Share -> ShareScreen(vm)
                HaloDestination.Settings -> SettingsScreen(vm, cloud)
            }
        }
    }

    // MR-RX-2: nothing is written until the person says yes. Not dismissable — declining is an explicit act.
    offer?.let { o ->
        AlertDialog(
            onDismissRequest = {},
            containerColor = HaloColors.Surface,
            title = { Text("${o.sender.alias} wants to send you", color = HaloColors.Text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("consent.title")) },
            text = {
                Column {
                    Text("${o.files.size} file${if (o.files.size == 1) "" else "s"} · ${formatBytes(o.totalBytes)}", color = HaloColors.Text2, modifier = Modifier.testTag("consent.summary"))
                    Text("from ${o.senderAddress}", color = HaloColors.Text3, fontSize = 12.sp)
                    Spacer(Modifier.height(10.dp))
                    Column(Modifier.background(HaloColors.Surface2, RoundedCornerShape(10.dp)).padding(10.dp).fillMaxWidth()) {
                        o.files.take(30).forEach { f ->
                            Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                                Text(f.fileName, color = HaloColors.Text, fontSize = 13.sp, maxLines = 1, modifier = Modifier.weight(1f))
                                Text(formatBytes(f.size), color = HaloColors.Text3, fontSize = 12.sp)
                            }
                        }
                        if (o.files.size > 30) Text("and ${o.files.size - 30} more…", color = HaloColors.Text3, fontSize = 12.sp)
                    }
                    Spacer(Modifier.height(10.dp))
                    Text("Only accept from people you know. Files are saved to Halo's Received folder.", color = HaloColors.Text3, fontSize = 12.sp)
                }
            },
            dismissButton = { HaloGhostButton("Decline", { vm.resolveConsent(ConsentDecision.DECLINE) }, Modifier.testTag("consent.decline")) },
            confirmButton = { HaloPrimaryButton("Accept", { vm.resolveConsent(ConsentDecision.ACCEPT) }, Modifier.testTag("consent.accept")) },
        )
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.NavItem(selected: Boolean, onClick: () -> Unit, colors: androidx.compose.material3.NavigationBarItemColors, label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, tag: String) =
    NavigationBarItem(selected = selected, onClick = onClick, colors = colors, label = { Text(label, maxLines = 1) }, icon = { Icon(icon, null) }, modifier = Modifier.testTag(tag))

// ── Share ──────────────────────────────────────────────────────────────────────────────────────

/** Nearby-devices grid, one big "Choose files", transfer progress, and what has been received. */
@Composable
fun ShareScreen(vm: AppViewModel) {
    val identity by vm.identity.collectAsStateWithLifecycle()
    val listen by vm.listen.collectAsStateWithLifecycle()
    val peers by vm.peers.collectAsStateWithLifecycle()
    val selected by vm.selectedPeerId.collectAsStateWithLifecycle()
    val selectedAlias = peers.firstOrNull { it.id == selected }?.alias
    val scanning by vm.scanning.collectAsStateWithLifecycle()
    val transfer by vm.transfer.collectAsStateWithLifecycle()
    val notice by vm.notice.collectAsStateWithLifecycle()
    val inbox by vm.inbox.collectAsStateWithLifecycle()
    var address by remember { mutableStateOf("") }
    var addressOpen by rememberSaveable { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    // The keyboard must be dismissable, or it covers the Send card: Add / Go / a tap outside all drop focus.
    fun submitAddress() { if (vm.addManual(address)) address = ""; focus.clearFocus() }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris -> if (uris.isNotEmpty()) vm.send(uris) }

    HaloScreen(HaloCopy.SHARE_TITLE, modifier = Modifier.pointerInput(Unit) { detectTapGestures { focus.clearFocus() } },
        trailing = { if (scanning) HaloIconButton(Icons.Filled.Close, "Stop scanning", vm::stopScan, tint = HaloColors.Text2) else HaloIconButton(Icons.Filled.Refresh, "Scan for devices", vm::scan, tint = HaloColors.Accent, filled = true, modifier = Modifier.testTag("share.scan")) }) {

        val sharedIn by vm.shared.collectAsStateWithLifecycle()
        if (sharedIn.isNotEmpty()) HaloCard(accentTop = HaloColors.Accent) {
            Text("${sharedIn.size} item${if (sharedIn.size == 1) "" else "s"} shared to Halo", color = HaloColors.Text, style = HaloType.Title, modifier = Modifier.testTag("share.sharedTitle"))
            val labels by vm.sharedLabels.collectAsStateWithLifecycle()
            if (labels.isNotEmpty()) Text(labels.joinToString(", ") + if (sharedIn.size > labels.size) " and ${sharedIn.size - labels.size} more" else "", color = HaloColors.Text2, fontSize = 12.sp, modifier = Modifier.testTag("share.sharedNames"))
            Text(if (selected == null) "Choose a device below, then tap Send. Nothing is sent until you do." else "Tap Send to send to ${selectedAlias ?: "the selected device"}. The other device still has to accept.", color = HaloColors.Text2, fontSize = 12.sp)
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                HaloPrimaryButton("Send", { vm.sendShared() }, Modifier.testTag("share.sendShared"), enabled = selected != null)
                HaloGhostButton("Discard", { vm.clearShared() }, Modifier.testTag("share.discardShared"))
            }
        }

        // This device: name + whether it can be reached.
        HaloCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                HaloAvatar(identity.alias, tint = HaloColors.Accent2)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(identity.alias, color = HaloColors.Text, style = HaloType.Title, modifier = Modifier.testTag("share.alias"))
                    val (color, text) = when (val l = listen) {
                        is ListenState.Listening -> HaloColors.Green to "Ready to receive · port ${l.port}"
                        ListenState.Starting -> HaloColors.Amber to "Starting…"
                        ListenState.Stopped -> HaloColors.Red to "Not listening"
                        is ListenState.Failed -> HaloColors.Red to "Can't receive: ${l.why}"
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(8.dp).background(color, androidx.compose.foundation.shape.CircleShape)); Spacer(Modifier.width(6.dp))
                        Text(text, color = HaloColors.Text2, fontSize = 12.sp, modifier = Modifier.testTag("share.status"))
                    }
                }
                HaloInfoButton(HaloCopy.INFO_TRANSPORT)
            }
        }

        HaloSectionHeader(HaloCopy.NEARBY, actionLabel = if (scanning) "Scanning…" else null, onAction = null)
        if (peers.isEmpty()) {
            HaloCard {
                if (scanning) Row(Modifier.fillMaxWidth().padding(vertical = 20.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = HaloColors.Accent); Spacer(Modifier.width(10.dp)); Text("Looking on your Wi-Fi…", color = HaloColors.Text2, fontSize = 13.sp)
                } else HaloEmptyState(Icons.Filled.Search, HaloCopy.NO_DEVICES, subtitle = HaloCopy.NO_DEVICES_SUB, actionLabel = HaloCopy.SCAN, onAction = vm::scan)
            }
        } else peers.chunked(2).forEach { pair ->
            Row(Modifier.height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                pair.forEach { DeviceTile(it, it.id == selected, Modifier.weight(1f).fillMaxHeight()) { vm.select(it.id) } }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
        notice?.let { Text(it, color = HaloColors.Amber, fontSize = 12.sp, modifier = Modifier.testTag("share.notice")) }

        // Send: the one big action + transfer progress.
        HaloSectionHeader("Send")
        HaloCard(accentTop = if (transfer is TransferState.Failed) HaloColors.Red else if (transfer is TransferState.Finished) HaloColors.Green else null) {
            when (val t = transfer) {
                TransferState.Idle -> Text(selectedAlias?.let { "To $it" } ?: "Pick a device above", color = HaloColors.Text2, fontSize = 13.sp)
                is TransferState.Sending -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    val p = (t.overallSent.toFloat() / maxOf(t.overallTotal, 1L)).coerceIn(0f, 1f)
                    HaloRing(p, size = 72.dp, strokeWidth = 7.dp, color = HaloColors.Accent, description = "Sending ${(p * 100).toInt()} percent") { Text("${(p * 100).toInt()}%", color = HaloColors.Text, fontWeight = FontWeight.Bold, fontSize = 16.sp) }
                    Column(Modifier.weight(1f)) {
                        Text("Sending ${t.fileName}", color = HaloColors.Text, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 2)
                        Text("${formatBytes(t.sent)} of ${formatBytes(t.total)}", color = HaloColors.Text2, fontSize = 12.sp)
                    }
                }
                is TransferState.Finished -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.CheckCircle, null, tint = HaloColors.Green, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(8.dp))
                    Text(t.message, color = HaloColors.Green, fontSize = 14.sp, modifier = Modifier.testTag("share.result"))
                }
                is TransferState.Failed -> Row(verticalAlignment = Alignment.Top) {
                    Icon(Icons.Filled.Warning, null, tint = HaloColors.Red, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(8.dp))
                    Text(t.why, color = HaloColors.Red, fontSize = 14.sp, modifier = Modifier.testTag("share.result"))
                }
            }
            Spacer(Modifier.height(12.dp))
            if (transfer.isBusy) HaloGhostButton("Cancel", vm::cancelSend, Modifier.testTag("share.cancel"), icon = Icons.Filled.Close)
            else Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                HaloPrimaryButton(HaloCopy.CHOOSE_FILES, { vm.dismissTransferResult(); picker.launch(arrayOf("*/*")) }, Modifier.weight(1f).testTag("share.chooseFiles"), icon = Icons.Filled.Share, enabled = selected != null)
                if (BuildConfig.DEBUG) HaloGhostButton("5 MB test", { vm.sendTestFile() }, Modifier.testTag("share.sendTest"), enabled = selected != null)
            }
        }

        // Add by address: for networks that block discovery (collapsed by default; the (i) says when to use it).
        HaloCard {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(HaloCopy.ADD_BY_ADDRESS, color = HaloColors.Text, fontSize = 15.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                HaloInfoButton(HaloCopy.INFO_ADDRESS)
                HaloGhostButton(if (addressOpen) "Hide" else "Add", { addressOpen = !addressOpen }, Modifier.testTag("share.addToggle"))
            }
            if (addressOpen) {
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = address, onValueChange = { address = it }, singleLine = true, colors = haloFieldColors(), modifier = Modifier.weight(1f).testTag("share.address"),
                        placeholder = { Text("192.168.1.20:53317", fontSize = 13.sp) },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                        keyboardActions = KeyboardActions(onGo = { submitAddress() }),
                    )
                    HaloPrimaryButton("Add", { submitAddress() }, Modifier.testTag("share.addAddress"), enabled = address.isNotBlank())
                }
            }
        }

        // Received files: compact rows.
        HaloSectionHeader(if (inbox.isEmpty()) HaloCopy.RECEIVED else "${HaloCopy.RECEIVED} (${inbox.size})", info = HaloCopy.INFO_RECEIVING)
        if (inbox.isEmpty()) HaloCard { HaloEmptyState(Icons.Filled.Email, HaloCopy.NOTHING_RECEIVED) }
        else HaloCard(contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 14.dp, vertical = 4.dp)) {
            inbox.forEach { item ->
                HaloListRow(item.name, subtitle = "${formatBytes(item.size)} · ${DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(item.modified))}", icon = Icons.Filled.Share, tint = HaloColors.Green,
                    modifier = Modifier.testTag("inbox.item.${item.name}"), trailing = { HaloIconButton(Icons.Filled.Delete, "Delete ${item.name}", { vm.deleteInboxItem(item) }, tint = HaloColors.Text2) })
            }
        }
    }
}

/** One nearby device: monogram, name, model · address, a check when chosen. The whole tile is the tap target. */
@Composable
private fun DeviceTile(peer: Peer, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    HaloCard(modifier.testTag("share.peer.${peer.alias}"), onClick = onClick, borderColor = if (selected) HaloColors.Accent else HaloColors.Border) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            HaloAvatar(peer.alias, tint = if (selected) HaloColors.Accent else HaloColors.Text2)
            Spacer(Modifier.weight(1f))
            if (selected) Icon(Icons.Filled.CheckCircle, "Selected", tint = HaloColors.Accent)
        }
        Spacer(Modifier.height(8.dp))
        Text(peer.alias, color = HaloColors.Text, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 2)
        Text(peer.info.deviceModel ?: peer.info.deviceType ?: "device", color = HaloColors.Text2, fontSize = 12.sp, maxLines = 1)
        Text(peer.host, color = HaloColors.Text3, fontSize = 11.sp, maxLines = 1)
    }
}

// ── Settings ───────────────────────────────────────────────────────────────────────────────────

@Composable
fun SettingsScreen(vm: AppViewModel, cloud: app.halo.mobile.cloud.CloudViewModel) {
    val identity by vm.identity.collectAsStateWithLifecycle()
    val listen by vm.listen.collectAsStateWithLifecycle()
    var alias by remember(identity.alias) { mutableStateOf(identity.alias) }

    HaloScreen(HaloCopy.SETTINGS_TITLE) {
        CloudSettingsCard(cloud)

        HaloCard {
            HaloSectionHeader("This device")
            OutlinedTextField(value = alias, onValueChange = { alias = it }, singleLine = true, label = { Text("Name") }, colors = haloFieldColors(),
                modifier = Modifier.fillMaxWidth().testTag("settings.alias"),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { vm.setAlias(alias) }))
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                HaloGhostButton("Save", { vm.setAlias(alias) }, enabled = alias.isNotBlank() && alias.trim() != identity.alias, icon = Icons.Filled.Check)
                Text("Other devices see this name.", color = HaloColors.Text2, fontSize = 12.sp)
            }
        }
        BackgroundReceiveCard(vm)
        HaloCard {
            HaloSectionHeader("Receiving", info = HaloCopy.INFO_RECEIVING)
            val (color, text) = when (val l = listen) { is ListenState.Listening -> HaloColors.Green to "Listening on ${l.port}"; ListenState.Starting -> HaloColors.Amber to "Starting…"; ListenState.Stopped -> HaloColors.Text2 to "Stopped"; is ListenState.Failed -> HaloColors.Red to l.why }
            HaloStatusBadge(text, color)
            Spacer(Modifier.height(6.dp))
            Text("Saved to: ${vm.receiveDirectory.path.substringAfter("Android/data/", vm.receiveDirectory.path)}", color = HaloColors.Text2, fontSize = 12.sp)
        }
        HaloCard {
            HaloSectionHeader("About HaloShare", info = HaloCopy.INFO_TRANSPORT)
            Text("LocalSend v2 · HTTP", color = HaloColors.Text, fontSize = 13.sp)
            Text("Fingerprint: ${identity.fingerprint.take(12)}…", color = HaloColors.Text2, fontSize = 12.sp)
        }
    }
}


// ── Background receiving (F-055) ───────────────────────────────────────────────────────────────

@Composable
fun BackgroundReceiveCard(vm: AppViewModel) {
    val on by vm.backgroundReceive.collectAsStateWithLifecycle()
    val paused by vm.pausedBySystem.collectAsStateWithLifecycle()
    val refusal by vm.backgroundRefusal.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    var rationale by remember { mutableStateOf(false) }
    // FR-B1: the persistent notification is required. A denial does NOT enable receiving; the switch stays off and the
    // refusal banner (driven by the settings, so it also explains a refusal made while the app was closed) says why.
    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { _ ->
        rationale = false; vm.onNotificationPermissionResult()
    }

    HaloCard {
        HaloToggleRow("Background receiving", on, { want ->
            if (!want) { vm.disableBackgroundReceive(); rationale = false }
            else if (vm.requestBackgroundReceive() == app.halo.mobile.background.BackgroundController.Enable.NEEDS_PERMISSION) rationale = true
        }, subtitle = "Receive with the app closed", info = HaloCopy.INFO_BACKGROUND, switchTag = Modifier.testTag("settings.background"))
        if (rationale) {
            Spacer(Modifier.height(8.dp))
            Text("Android requires a notification while Halo listens, so you can see it is on and stop it. Halo will also use notifications to ask before saving a file when the app is closed. Next: Android asks for notification permission.", color = HaloColors.Text2, fontSize = 12.sp, modifier = Modifier.testTag("settings.background.rationale"))
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                HaloPrimaryButton("Continue", { askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS) }, Modifier.testTag("settings.background.continue"))
                HaloGhostButton("Not now", { rationale = false })
            }
        }
        if (refusal != null) {
            Spacer(Modifier.height(10.dp))
            HaloBanner("Background receiving is off: Android is hiding Halo's notifications.",
                info = HaloCopy.INFO_NOTIFICATION_GATE, textModifier = Modifier.testTag("settings.background.refused"), actionLabel = "Open notification settings",
                onAction = {
                    ctx.startActivity(android.content.Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, ctx.packageName).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
                }, actionTag = Modifier.testTag("settings.background.openSettings"))
        }
        if (paused) { Spacer(Modifier.height(10.dp)); HaloBanner("Android paused background receiving (it limits this kind of service to a few hours a day). Switch it off and on to resume.", textModifier = Modifier.testTag("settings.background.paused")) }
    }
}

/** Debug gallery only: two nearby-device tiles (one chosen) so the Share grid can be checked without a second device on the network. */
@Composable
internal fun DeviceTilesSample() {
    val a = Peer(app.halo.share.DeviceInfo(alias = "MacBook Pro", deviceModel = "MacBookPro18,3", deviceType = "desktop", fingerprint = "aaaa"), "192.168.1.20")
    val b = Peer(app.halo.share.DeviceInfo(alias = "Pixel 9 with a very long device name", deviceModel = "Pixel 9", deviceType = "mobile", fingerprint = "bbbb"), "192.168.1.31")
    HaloSectionHeader(HaloCopy.NEARBY)
    Row(Modifier.height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        DeviceTile(a, true, Modifier.weight(1f).fillMaxHeight()) {}
        DeviceTile(b, false, Modifier.weight(1f).fillMaxHeight()) {}
    }
}
