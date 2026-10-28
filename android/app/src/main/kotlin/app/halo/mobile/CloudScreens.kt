package app.halo.mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.halo.mobile.cloud.ClipItem
import app.halo.mobile.cloud.CloudViewModel
import app.halo.mobile.cloud.LineUi
import app.halo.cloud.PairingConfirmation
import app.halo.mobile.cloud.PairUi
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import java.text.DateFormat
import java.util.Date

// ── Pairing ────────────────────────────────────────────────────────────────────────────────────

@Composable
fun PairingPanel(vm: CloudViewModel, why: String) {
    val pair by vm.pair.collectAsStateWithLifecycle()
    var code by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    val ctx = LocalContext.current
    val scanner = rememberLauncherForActivityResult(ScanContract()) { r -> r.contents?.let { code = it; vm.submitCode(it) } }

    HaloCard {
        SectionLabel("Connect to your Mac")
        Spacer(Modifier.height(8.dp))
        Text(why, color = Halo.Text2, fontSize = 13.sp)
        Spacer(Modifier.height(12.dp))
        when (val p = pair) {
            is PairUi.Working -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp); Spacer(Modifier.width(10.dp))
                Text(p.what, color = Halo.Text2, fontSize = 13.sp, modifier = Modifier.testTag("pair.working"))
            }
            is PairUi.NeedsPassphrase -> {
                Text("Paired with ${p.payload.firebaseConfig.projectID}.", color = Halo.Green, fontSize = 13.sp, modifier = Modifier.testTag("pair.accepted"))
                p.hostWarning?.let { Spacer(Modifier.height(6.dp)); Text(it, color = Halo.Amber, fontSize = 12.sp, modifier = Modifier.testTag("pair.hostWarning")) }
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(passphrase, { passphrase = it }, singleLine = true, label = { Text("Encryption passphrase") },
                    visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth().testTag("pair.passphrase"),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                Text("The one you set on your Mac. It is never sent anywhere and is not stored on this phone — only the key derived from it is, sealed in the Android Keystore.", color = Halo.Text3, fontSize = 11.sp)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(onClick = { vm.connect(p.payload, passphrase) }, modifier = Modifier.testTag("pair.connect")) { Text("Connect") }
                    OutlinedButton(onClick = { passphrase = ""; vm.cancelPairing() }) { Text("Back") }
                }
            }
            is PairUi.NeedsConfirmation -> {
                Text("Paired with ${p.payload.firebaseConfig.projectID}.", color = Halo.Green, fontSize = 13.sp, modifier = Modifier.testTag("pair.accepted"))
                Spacer(Modifier.height(8.dp))
                Text(PairingConfirmation.NOTICE, color = Halo.Amber, fontSize = 12.sp, modifier = Modifier.testTag("pair.notice"))
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(confirmation, { confirmation = it }, singleLine = true, label = { Text("Type the passphrase again") },
                    visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth().testTag("pair.confirm"),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                p.error?.let { Spacer(Modifier.height(6.dp)); Text(it, color = Halo.Red, fontSize = 12.sp, modifier = Modifier.testTag("pair.error")) }
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(onClick = { vm.confirm(confirmation) }, enabled = confirmation.isNotEmpty(), modifier = Modifier.testTag("pair.confirmButton")) { Text("Confirm") }
                    OutlinedButton(onClick = { passphrase = ""; confirmation = ""; vm.cancelPairing() }) { Text("Back") }
                }
            }
            else -> {
                OutlinedTextField(code, { code = it }, label = { Text("Pairing code") }, minLines = 2, maxLines = 4,
                    modifier = Modifier.fillMaxWidth().testTag("pair.code"))
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(onClick = { vm.submitCode(code) }, enabled = code.isNotBlank(), modifier = Modifier.testTag("pair.submit")) { Text("Pair") }
                    OutlinedButton(onClick = { scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan the pairing code on your Mac").setBeepEnabled(false).setOrientationLocked(false)) },
                        modifier = Modifier.testTag("pair.scan")) { Text("Scan QR") }
                    TextButton(onClick = { app.halo.mobile.cloud.ClipboardController.readClipboard(ctx)?.let { code = it } }) { Text("Paste") }
                }
                (p as? PairUi.Failed)?.let { Spacer(Modifier.height(8.dp)); Text(it.why, color = Halo.Red, fontSize = 12.sp, modifier = Modifier.testTag("pair.error")) }
                Spacer(Modifier.height(8.dp))
                Text("On your Mac: Messages → the gear → Pair a phone → Show pairing code. The code contains your sign-in, not your passphrase.", color = Halo.Text3, fontSize = 11.sp)
            }
        }
    }
}

// ── SMS ────────────────────────────────────────────────────────────────────────────────────────

private val SMS_PERMISSIONS = arrayOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS, Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_PHONE_NUMBERS)

@Composable
fun SmsScreen(vm: CloudViewModel) {
    val profile by vm.profile.collectAsStateWithLifecycle()
    val enabled by vm.smsEnabled.collectAsStateWithLifecycle()
    val lines by vm.lines.collectAsStateWithLifecycle()
    val syncing by vm.syncing.collectAsStateWithLifecycle()
    val notice by vm.notice.collectAsStateWithLifecycle()
    val warning by vm.warning.collectAsStateWithLifecycle()
    vm.syncTick.collectAsStateWithLifecycle()                      // re-read the last-sync facts after each run
    val ctx = LocalContext.current
    fun granted(p: String) = ContextCompat.checkSelfPermission(ctx, p) == PackageManager.PERMISSION_GRANTED
    var canRead by remember { mutableStateOf(granted(Manifest.permission.READ_SMS)) }
    var canSeeSims by remember { mutableStateOf(granted(Manifest.permission.READ_PHONE_STATE)) }
    val askPermissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        canRead = granted(Manifest.permission.READ_SMS); canSeeSims = granted(Manifest.permission.READ_PHONE_STATE)
        if (canRead) { vm.setSmsEnabled(true); vm.refreshLines() }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        canRead = granted(Manifest.permission.READ_SMS); canSeeSims = granted(Manifest.permission.READ_PHONE_STATE)
        if (profile != null) vm.refreshLines()
    }
    var allow by remember { mutableStateOf(vm.prefs.allow.joinToString(", ")) }
    var deny by remember { mutableStateOf(vm.prefs.deny.joinToString(", ")) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("SMS", color = Halo.Text, fontSize = 34.sp, fontWeight = FontWeight.Bold)
        if (profile == null) {
            PairingPanel(vm, "Pair this phone with your Mac to sync your text messages to the Halo console. Everything is encrypted on the phone before it leaves.")
            return@Column
        }
        warning?.let { HaloCard { Row(verticalAlignment = Alignment.Top) { Icon(Icons.Filled.Warning, null, tint = Halo.Amber, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(it, color = Halo.Amber, fontSize = 12.sp) } } }

        HaloCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Sync messages to my Mac", color = Halo.Text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                    Text(if (canRead) "Inbox only. Encrypted before upload." else "Needs permission to read your messages.", color = Halo.Text3, fontSize = 11.sp)
                }
                Switch(checked = enabled && canRead, onCheckedChange = { on ->
                    if (!on) vm.setSmsEnabled(false)
                    else if (canRead) vm.setSmsEnabled(true) else askPermissions.launch(SMS_PERMISSIONS)
                }, modifier = Modifier.testTag("sms.toggle"))
            }
            if (!canRead) {
                Spacer(Modifier.height(10.dp))
                Text("Why Halo asks: it reads your inbox so your Mac can show it, and is told when a message arrives so it appears promptly. Your phone's phone-number permission is only used to name your SIM lines. Nothing is sent unencrypted, and you can turn this off at any time.", color = Halo.Text2, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                Button(onClick = { askPermissions.launch(SMS_PERMISSIONS) }, modifier = Modifier.testTag("sms.grant")) { Text("Allow SMS access") }
            }
        }

        if (enabled && canRead) {
            val prefs = vm.prefs
            HaloCard {
                SectionLabel("Last sync"); Spacer(Modifier.height(6.dp))
                val last = prefs.lastSyncAt
                Text(if (last == 0L) "Not yet" else DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(last)) + " · " + prefs.lastSyncSummary,
                    color = Halo.Text2, fontSize = 13.sp, modifier = Modifier.testTag("sms.last"))
                prefs.lastSyncError?.let { Text(it, color = Halo.Red, fontSize = 12.sp, modifier = Modifier.testTag("sms.error")) }
                notice?.let { Text(it, color = Halo.Text2, fontSize = 12.sp, modifier = Modifier.testTag("sms.notice")) }
                val skipped = prefs.quarantinedCount
                if (skipped > 0) {
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(if (skipped == 1) "1 message couldn't be synced" else "$skipped messages couldn't be synced", color = Halo.Amber, fontSize = 12.sp,
                            modifier = Modifier.weight(1f).testTag("sms.skipped"))
                        TextButton(onClick = { vm.retrySkipped() }, enabled = !syncing, modifier = Modifier.testTag("sms.retrySkipped")) { Text("Retry skipped") }
                    }
                }
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Button(onClick = { vm.syncNow(reconcile = true) }, enabled = !syncing, modifier = Modifier.testTag("sms.syncNow")) {
                        if (syncing) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Halo.Text) else Icon(Icons.Filled.Refresh, null, Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp)); Text("Sync now")
                    }
                    OutlinedButton(onClick = { vm.extendHistory(365) }, enabled = !syncing) { Text("Sync older history") }
                }
                Spacer(Modifier.height(6.dp))
                Text("The first sync covers the last ${prefs.backfillDays} days. Messages you delete on this phone are removed from the cloud too.", color = Halo.Text3, fontSize = 11.sp)
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SectionLabel("SIM lines")
                if (!canSeeSims) HaloCard { Text("Allow phone access to see each SIM's name and number. Until then everything syncs as one line.", color = Halo.Text3, fontSize = 12.sp) }
                lines.forEach { LineCard(it, vm) }
            }

            HaloCard {
                SectionLabel("Who to sync"); Spacer(Modifier.height(6.dp))
                OutlinedTextField(allow, { allow = it }, label = { Text("Only these senders (optional)") }, modifier = Modifier.fillMaxWidth().testTag("sms.allow"), minLines = 1, maxLines = 3)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(deny, { deny = it }, label = { Text("Never these senders") }, modifier = Modifier.fillMaxWidth().testTag("sms.deny"), minLines = 1, maxLines = 3)
                Text("Numbers or sender names, separated by commas. A blocked sender always wins.", color = Halo.Text3, fontSize = 11.sp)
                TextButton(onClick = { vm.setFilters(allow, deny) }) { Text("Save filters") }
            }
        }
    }
}

@Composable
private fun LineCard(l: LineUi, vm: CloudViewModel) {
    var editing by remember { mutableStateOf(false) }
    var label by remember(l.line.label) { mutableStateOf(l.line.label) }
    var number by remember(l.line.ownNumber) { mutableStateOf(l.line.ownNumber) }
    HaloCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(l.line.label, color = Halo.Text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                Text("${l.line.ownNumber.ifBlank { "number not provided" }} · ${l.line.carrier}", color = Halo.Text3, fontSize = 11.sp)
            }
            Switch(checked = l.enabled, onCheckedChange = { vm.setLineEnabled(l.line.subscriptionId, it) }, modifier = Modifier.testTag("sms.line.${l.line.subscriptionId}"))
        }
        TextButton(onClick = { editing = !editing }) { Text(if (editing) "Close" else "Rename / set number") }
        if (editing) {
            OutlinedTextField(label, { label = it }, singleLine = true, label = { Text("Name (e.g. Personal)") }, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(6.dp))
            OutlinedTextField(number, { number = it }, singleLine = true, label = { Text("This SIM's phone number") }, modifier = Modifier.fillMaxWidth())
            TextButton(onClick = { vm.saveLine(l.line.subscriptionId, label, number); editing = false }) { Text("Save") }
        }
    }
}

// ── Clipboard ──────────────────────────────────────────────────────────────────────────────────

@Composable
fun ClipboardScreen(vm: CloudViewModel) {
    val profile by vm.profile.collectAsStateWithLifecycle()
    val enabled by vm.clipEnabled.collectAsStateWithLifecycle()
    val filter by vm.clipFilter.collectAsStateWithLifecycle()
    val history by vm.history.collectAsStateWithLifecycle()
    val notice by vm.clipNotice.collectAsStateWithLifecycle()
    val status by vm.clipStatus.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    var accessibility by remember { mutableStateOf(vm.accessibilityEnabled()) }
    var confirmPurge by remember { mutableStateOf(false) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { accessibility = vm.accessibilityEnabled() }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Clipboard", color = Halo.Text, fontSize = 34.sp, fontWeight = FontWeight.Bold)
        if (profile == null) {
            PairingPanel(vm, "Pair this phone with your Mac to share your clipboard between them. Copies are encrypted before they leave.")
            return@Column
        }
        HaloCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Sync my clipboard", color = Halo.Text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                    Text("Text and links. What you copy on your Mac shows up below — it never replaces what you're about to paste.", color = Halo.Text3, fontSize = 11.sp)
                }
                Switch(checked = enabled, onCheckedChange = vm::setClipboardEnabled, modifier = Modifier.testTag("clip.toggle"))
            }
            if (status.isNotBlank()) Text(status, color = Halo.Text2, fontSize = 12.sp, modifier = Modifier.testTag("clip.status"))
            notice?.let { Text(it, color = Halo.Text2, fontSize = 12.sp, modifier = Modifier.testTag("clip.notice")) }
        }

        HaloCard {
            SectionLabel("Send to your Mac"); Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(onClick = vm::sendClipboardNow, enabled = enabled, modifier = Modifier.testTag("clip.sendNow")) { Text("Send clipboard now") }
            }
            Spacer(Modifier.height(6.dp))
            Text("You can also share text from any app → “Send to Mac (Halo)”. That works on every Android version.", color = Halo.Text3, fontSize = 11.sp)
        }

        HaloCard {
            SectionLabel("Automatic capture"); Spacer(Modifier.height(8.dp))
            Text(if (accessibility) "Halo clipboard sync is on — copies are sent as you make them." else "Off. Android only lets an app read the clipboard in the background through an accessibility service, so to sync automatically turn Halo on in Accessibility settings. Halo does not read your screen or what you type.",
                color = if (accessibility) Halo.Green else Halo.Text2, fontSize = 12.sp, modifier = Modifier.testTag("clip.a11y"))
            if (!accessibility) {
                Spacer(Modifier.height(8.dp))
                OutlinedButton(onClick = { ctx.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }, modifier = Modifier.testTag("clip.openA11y")) { Text("Open Accessibility settings") }
            }
        }

        HaloCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Keep likely secrets off the cloud", color = Halo.Text, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                    Text("Off by default. When on, copies that look like passwords or keys are not sent.", color = Halo.Text3, fontSize = 11.sp)
                }
                Switch(checked = filter, onCheckedChange = vm::setClipboardFilter)
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                SectionLabel("History")
                if (history.isNotEmpty()) TextButton(onClick = { confirmPurge = true }) { Icon(Icons.Filled.Delete, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text("Purge synced") }
            }
            if (history.isEmpty()) HaloCard { Text("Nothing synced yet.", color = Halo.Text3, fontSize = 13.sp) }
            history.take(50).forEach { ClipRow(it) { vm.copy(it) } }
        }
    }
    if (confirmPurge) androidx.compose.material3.AlertDialog(
        onDismissRequest = { confirmPurge = false }, containerColor = Halo.Background,
        title = { Text("Remove synced clipboard?", color = Halo.Text) },
        text = { Text("This deletes every synced clipboard item from your cloud and from this phone. Your Mac keeps its own history.", color = Halo.Text2) },
        confirmButton = { Button(onClick = { vm.purgeClipboard(); confirmPurge = false }, modifier = Modifier.testTag("clip.purgeConfirm")) { Text("Remove") } },
        dismissButton = { OutlinedButton(onClick = { confirmPurge = false }) { Text("Cancel") } },
    )
}

@Composable
private fun ClipRow(item: ClipItem, onCopy: () -> Unit) {
    Column(Modifier.fillMaxWidth().background(Halo.Surface, RoundedCornerShape(12.dp)).padding(12.dp).testTag("clip.item")) {
        Text(item.text, color = Halo.Text, fontSize = 14.sp, maxLines = 4)
        Spacer(Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("${if (item.received) "From" else "Sent from"} ${item.from} · ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(item.atMs))}", color = Halo.Text3, fontSize = 11.sp, modifier = Modifier.weight(1f))
            TextButton(onClick = onCopy) { Text("Copy") }
        }
    }
}

// ── Settings block ─────────────────────────────────────────────────────────────────────────────

@Composable
fun CloudSettingsCard(vm: CloudViewModel) {
    val profile by vm.profile.collectAsStateWithLifecycle()
    var name by remember { mutableStateOf(vm.deviceName) }
    var confirm by remember { mutableStateOf(false) }
    HaloCard {
        SectionLabel("Halo cloud"); Spacer(Modifier.height(8.dp))
        val p = profile
        if (p == null) Text("Not paired. Pair from the SMS or Clipboard tab.", color = Halo.Text3, fontSize = 13.sp)
        else {
            Text("Connected to ${p.config.projectID}", color = Halo.Green, fontSize = 13.sp, modifier = Modifier.testTag("settings.cloud"))
            Text("Signed in as ${p.auth.email}", color = Halo.Text3, fontSize = 11.sp)
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(name, { name = it }, singleLine = true, label = { Text("This phone's name on your Mac") }, modifier = Modifier.fillMaxWidth())
            TextButton(onClick = { vm.deviceName = name }, enabled = name.isNotBlank() && name.trim() != vm.deviceName) { Text("Save name") }
            OutlinedButton(onClick = { confirm = true }, modifier = Modifier.testTag("settings.disconnect")) { Text("Disconnect") }
            Text("Forgets the connection and the key on this phone. Your messages and cloud data are not deleted.", color = Halo.Text3, fontSize = 11.sp)
        }
    }
    if (confirm) androidx.compose.material3.AlertDialog(
        onDismissRequest = { confirm = false }, containerColor = Halo.Background,
        title = { Text("Disconnect this phone?", color = Halo.Text) },
        text = { Text("SMS and clipboard sync stop. You can pair again any time with a new code from your Mac.", color = Halo.Text2) },
        confirmButton = { Button(onClick = { vm.disconnect(); confirm = false }) { Text("Disconnect") } },
        dismissButton = { OutlinedButton(onClick = { confirm = false }) { Text("Cancel") } },
    )
}
