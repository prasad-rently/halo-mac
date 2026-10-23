package app.halo.mobile

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.halo.share.ConsentDecision
import app.halo.share.Peer
import java.text.DateFormat
import java.util.Date

@Composable
fun HaloApp(vm: AppViewModel) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val offer by vm.pendingOffer.collectAsStateWithLifecycle()
    val inbox by vm.inbox.collectAsStateWithLifecycle()
    val transfer by vm.transfer.collectAsStateWithLifecycle()

    // MR-OS-3: keep the screen (and so the connection) awake for the length of a transfer.
    val view = LocalView.current
    view.keepScreenOn = transfer.isBusy || offer != null

    Scaffold(
        containerColor = Halo.Background,
        bottomBar = {
            NavigationBar(containerColor = Halo.Surface) {
                val colors = NavigationBarItemDefaults.colors(selectedIconColor = Halo.Accent, selectedTextColor = Halo.Accent,
                    indicatorColor = Halo.Accent.copy(alpha = 0.16f), unselectedIconColor = Halo.Text3, unselectedTextColor = Halo.Text3)
                NavigationBarItem(selected = tab == 0, onClick = { tab = 0 }, colors = colors, label = { Text("Share") },
                    icon = { Icon(Icons.Filled.Share, null) }, modifier = Modifier.testTag("tab.share"))
                NavigationBarItem(selected = tab == 1, onClick = { tab = 1; vm.refreshInbox() }, colors = colors,
                    label = { Text(if (inbox.isEmpty()) "Inbox" else "Inbox (${inbox.size})") },
                    icon = { Icon(Icons.Filled.Email, null) }, modifier = Modifier.testTag("tab.inbox"))
                NavigationBarItem(selected = tab == 2, onClick = { tab = 2 }, colors = colors, label = { Text("Settings") },
                    icon = { Icon(Icons.Filled.Settings, null) }, modifier = Modifier.testTag("tab.settings"))
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when (tab) { 0 -> ShareScreen(vm); 1 -> InboxScreen(vm); else -> SettingsScreen(vm) }
        }
    }

    // MR-RX-2: nothing is written until the person says yes. Not dismissable — declining is an explicit act.
    offer?.let { o ->
        AlertDialog(
            onDismissRequest = {},
            containerColor = Halo.Background,
            title = { Text("${o.sender.alias} wants to send you", color = Halo.Text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("consent.title")) },
            text = {
                Column {
                    Text("${o.files.size} file${if (o.files.size == 1) "" else "s"} · ${formatBytes(o.totalBytes)}", color = Halo.Text2, modifier = Modifier.testTag("consent.summary"))
                    Text("from ${o.senderAddress}", color = Halo.Text3, fontSize = 11.sp)
                    Spacer(Modifier.height(10.dp))
                    Column(Modifier.background(Halo.Surface, RoundedCornerShape(10.dp)).padding(10.dp).fillMaxWidth()) {
                        o.files.take(30).forEach { f ->
                            Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                                Text(f.fileName, color = Halo.Text, fontSize = 13.sp, maxLines = 1, modifier = Modifier.weight(1f))
                                Text(formatBytes(f.size), color = Halo.Text3, fontSize = 11.sp)
                            }
                        }
                        if (o.files.size > 30) Text("and ${o.files.size - 30} more…", color = Halo.Text3, fontSize = 12.sp)
                    }
                    Spacer(Modifier.height(10.dp))
                    Text("Only accept from people you know. Files are saved to Halo's Received folder.", color = Halo.Text3, fontSize = 11.sp)
                }
            },
            dismissButton = { OutlinedButton(onClick = { vm.resolveConsent(ConsentDecision.DECLINE) }, modifier = Modifier.testTag("consent.decline")) { Text("Decline") } },
            confirmButton = { Button(onClick = { vm.resolveConsent(ConsentDecision.ACCEPT) }, modifier = Modifier.testTag("consent.accept")) { Text("Accept") } },
        )
    }
}

// ── Share ──────────────────────────────────────────────────────────────────────────────────────

@Composable
fun ShareScreen(vm: AppViewModel) {
    val identity by vm.identity.collectAsStateWithLifecycle()
    val listen by vm.listen.collectAsStateWithLifecycle()
    val peers by vm.peers.collectAsStateWithLifecycle()
    val selected by vm.selectedPeerId.collectAsStateWithLifecycle()
    val scanning by vm.scanning.collectAsStateWithLifecycle()
    val transfer by vm.transfer.collectAsStateWithLifecycle()
    val notice by vm.notice.collectAsStateWithLifecycle()
    var address by remember { mutableStateOf("") }
    val focus = LocalFocusManager.current
    // The keyboard must be dismissable, or it covers the Send card: Add / Go / a tap outside all drop focus.
    fun submitAddress() { if (vm.addManual(address)) address = ""; focus.clearFocus() }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris -> if (uris.isNotEmpty()) vm.send(uris) }

    Column(Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { focus.clearFocus() } }
        .verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Text("Halo", color = Halo.Text, fontSize = 34.sp, fontWeight = FontWeight.Bold)

        HaloCard {
            Text(identity.alias, color = Halo.Text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("share.alias"))
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                val (color, text) = when (val l = listen) {
                    is ListenState.Listening -> Halo.Green to "Ready to receive · port ${l.port}"
                    ListenState.Starting -> Halo.Amber to "Starting…"
                    ListenState.Stopped -> Halo.Red to "Not listening"
                    is ListenState.Failed -> Halo.Red to "Can't receive: ${l.why}"
                }
                Box(Modifier.size(8.dp).background(color, CircleShape)); Spacer(Modifier.width(6.dp))
                Text(text, color = Halo.Text2, fontSize = 12.sp, modifier = Modifier.testTag("share.status"))
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                SectionLabel("Nearby devices")
                if (scanning) TextButton(onClick = vm::stopScan) { Text("Stop scanning") }
                else TextButton(onClick = vm::scan, modifier = Modifier.testTag("share.scan")) { Icon(Icons.Filled.Refresh, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text("Scan") }
            }
            if (peers.isEmpty()) {
                HaloCard { Text(if (scanning) "Looking on your Wi-Fi…" else "No devices yet. Tap Scan, or add an address below.", color = Halo.Text3, fontSize = 13.sp) }
            } else peers.forEach { PeerRow(it, it.id == selected) { vm.select(it.id) } }
            notice?.let { Text(it, color = Halo.Amber, fontSize = 12.sp, modifier = Modifier.testTag("share.notice")) }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionLabel("Add by address")
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = address, onValueChange = { address = it }, singleLine = true, modifier = Modifier.weight(1f).testTag("share.address"),
                    placeholder = { Text("192.168.1.20 or 192.168.1.20:53317", color = Halo.Text3, fontSize = 13.sp) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { submitAddress() }),
                )
                Button(onClick = { submitAddress() }, enabled = address.isNotBlank(), modifier = Modifier.testTag("share.addAddress")) { Text("Add") }
            }
            Text("For networks that block discovery. Use the address shown on the other device.", color = Halo.Text3, fontSize = 11.sp)
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionLabel("Send")
            HaloCard {
                when (val t = transfer) {
                    TransferState.Idle -> Text(peers.firstOrNull { it.id == selected }?.let { "To ${it.alias}" } ?: "Choose a device above", color = Halo.Text2, fontSize = 13.sp)
                    is TransferState.Sending -> {
                        Text("Sending ${t.fileName}", color = Halo.Text, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(8.dp))
                        LinearProgressIndicator(progress = { (t.overallSent.toFloat() / maxOf(t.overallTotal, 1L)).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth(), color = Halo.Accent)
                        Spacer(Modifier.height(4.dp))
                        Text("${formatBytes(t.sent)} of ${formatBytes(t.total)}", color = Halo.Text3, fontSize = 11.sp)
                    }
                    is TransferState.Finished -> Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.CheckCircle, null, tint = Halo.Green, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(6.dp))
                        Text(t.message, color = Halo.Green, fontSize = 13.sp, modifier = Modifier.testTag("share.result"))
                    }
                    is TransferState.Failed -> Text(t.why, color = Halo.Red, fontSize = 13.sp, modifier = Modifier.testTag("share.result"))
                }
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (transfer.isBusy) {
                        OutlinedButton(onClick = vm::cancelSend, modifier = Modifier.testTag("share.cancel")) { Icon(Icons.Filled.Close, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text("Cancel") }
                    } else {
                        Button(onClick = { vm.dismissTransferResult(); picker.launch(arrayOf("*/*")) }, enabled = selected != null, modifier = Modifier.testTag("share.chooseFiles")) { Text("Choose files…") }
                        if (BuildConfig.DEBUG) OutlinedButton(onClick = { vm.sendTestFile() }, enabled = selected != null, modifier = Modifier.testTag("share.sendTest")) { Text("Send 5 MB test") }
                    }
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.testTag("share.cloudFeatures")) {
            SectionLabel("Coming with the Halo cloud foundation")
            HaloCard {
                BlockedRow("SMS sync", "Reads your messages and syncs them to your Mac")
                Spacer(Modifier.height(10.dp))
                BlockedRow("Clipboard sync", "Phone ↔ Mac")
                Spacer(Modifier.height(10.dp))
                BlockedRow("Pair with your Mac", "Scan a QR to connect your Firebase")
                Spacer(Modifier.height(10.dp))
                Text("These need the shared cloud layer (F-044) that hasn't been built yet. HaloShare doesn't — it works today.", color = Halo.Text3, fontSize = 11.sp)
            }
        }
    }
}

@Composable
private fun PeerRow(peer: Peer, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .background(if (selected) Halo.Accent.copy(alpha = 0.12f) else Halo.Surface, RoundedCornerShape(12.dp))
            .border(1.dp, if (selected) Halo.Accent.copy(alpha = 0.5f) else Halo.Border, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick).padding(12.dp).testTag("share.peer.${peer.alias}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(34.dp).background(Halo.Surface2, CircleShape), contentAlignment = Alignment.Center) {
            Text(peer.alias.take(1).uppercase(), color = if (selected) Halo.Accent else Halo.Text2, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(peer.alias, color = Halo.Text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text("${peer.info.deviceModel ?: peer.info.deviceType ?: "device"} · ${peer.host}", color = Halo.Text3, fontSize = 11.sp)
        }
        if (selected) Icon(Icons.Filled.CheckCircle, null, tint = Halo.Accent)
    }
}

@Composable
private fun BlockedRow(title: String, subtitle: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = Halo.Text2, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(subtitle, color = Halo.Text3, fontSize = 11.sp)
        }
        Text("Not yet", color = Halo.Amber, fontSize = 10.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.background(Halo.Amber.copy(alpha = 0.14f), RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 3.dp))
    }
}

// ── Inbox ──────────────────────────────────────────────────────────────────────────────────────

@Composable
fun InboxScreen(vm: AppViewModel) {
    val inbox by vm.inbox.collectAsStateWithLifecycle()
    if (inbox.isEmpty()) {
        Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Nothing received yet", color = Halo.Text2, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(6.dp))
            Text("Files sent to this device appear here.", color = Halo.Text3, fontSize = 12.sp)
        }
    } else {
        LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item { Text("Inbox", color = Halo.Text, fontSize = 34.sp, fontWeight = FontWeight.Bold) }
            items(inbox, key = { it.file.path }) { item ->
                Row(Modifier.fillMaxWidth().background(Halo.Surface, RoundedCornerShape(12.dp)).padding(12.dp).testTag("inbox.item.${item.name}"), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(item.name, color = Halo.Text, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                        Text("${formatBytes(item.size)} · ${DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(item.modified))}", color = Halo.Text3, fontSize = 11.sp)
                    }
                    IconButton(onClick = { vm.deleteInboxItem(item) }) { Icon(Icons.Filled.Delete, "Delete", tint = Halo.Text3) }
                }
            }
        }
    }
}

// ── Settings ───────────────────────────────────────────────────────────────────────────────────

@Composable
fun SettingsScreen(vm: AppViewModel) {
    val identity by vm.identity.collectAsStateWithLifecycle()
    val listen by vm.listen.collectAsStateWithLifecycle()
    var alias by remember(identity.alias) { mutableStateOf(identity.alias) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Text("Settings", color = Halo.Text, fontSize = 34.sp, fontWeight = FontWeight.Bold)

        HaloCard {
            SectionLabel("This device")
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(value = alias, onValueChange = { alias = it }, singleLine = true, label = { Text("Name") },
                modifier = Modifier.fillMaxWidth().testTag("settings.alias"),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { vm.setAlias(alias) }))
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { vm.setAlias(alias) }, enabled = alias.isNotBlank() && alias.trim() != identity.alias) { Icon(Icons.Filled.Check, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text("Save") }
                Text("Other devices see this name.", color = Halo.Text3, fontSize = 11.sp)
            }
        }
        HaloCard {
            SectionLabel("Receiving")
            Spacer(Modifier.height(8.dp))
            Text(when (val l = listen) { is ListenState.Listening -> "Listening on ${l.port}"; ListenState.Starting -> "Starting…"; ListenState.Stopped -> "Stopped"; is ListenState.Failed -> l.why }, color = Halo.Text2, fontSize = 13.sp)
            Text("Saved to: ${vm.receiveDirectory.path.substringAfter("Android/data/", vm.receiveDirectory.path)}", color = Halo.Text3, fontSize = 11.sp)
            Spacer(Modifier.height(4.dp))
            Text("Nothing is saved until you accept. Files never overwrite each other.", color = Halo.Text3, fontSize = 11.sp)
        }
        HaloCard {
            SectionLabel("About HaloShare")
            Spacer(Modifier.height(8.dp))
            Text("Protocol: LocalSend v2 · HTTP", color = Halo.Text2, fontSize = 13.sp)
            Text("Fingerprint: ${identity.fingerprint.take(12)}…", color = Halo.Text3, fontSize = 12.sp)
            Spacer(Modifier.height(4.dp))
            Text("Transfers stay on your Wi-Fi and are not encrypted in transit. Only accept files from people you trust.", color = Halo.Text3, fontSize = 11.sp)
        }
    }
}
