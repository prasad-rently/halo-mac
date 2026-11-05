package app.halo.mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.halo.cloud.PairingConfirmation
import androidx.lifecycle.viewmodel.compose.viewModel
import app.halo.mobile.cloud.ClipItem
import app.halo.mobile.tools.ToolsViewModel
import app.halo.mobile.cloud.CloudViewModel
import app.halo.mobile.cloud.LineUi
import app.halo.mobile.cloud.LocalInbox
import app.halo.mobile.cloud.LocalMessage
import app.halo.mobile.cloud.PairUi
import app.halo.mobile.cloud.ProfileProblem
import app.halo.mobile.design.*
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

// ── Pairing ────────────────────────────────────────────────────────────────────────────────────

/** Pairing as a three-step card: code -> passphrase -> confirm. The long "why / how" copy sits behind the (i). */
@Composable
fun PairingPanel(vm: CloudViewModel, why: String) {
    val pair by vm.pair.collectAsStateWithLifecycle()
    var code by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    val ctx = LocalContext.current
    val scanner = rememberLauncherForActivityResult(ScanContract()) { r -> r.contents?.let { code = it; vm.submitCode(it) } }
    val step = when (pair) { is PairUi.NeedsPassphrase -> 1; is PairUi.NeedsConfirmation -> 2; else -> 0 }
    val info = HaloCopy.INFO_PAIRING.copy(body = why, extra = listOf(HaloCopy.INFO_PAIRING.body) + HaloCopy.INFO_PAIRING.extra)

    HaloCard {
        HaloSectionHeader("Connect to Mac", info = info)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.horizontalScroll(rememberScrollState())) {
            listOf("1  Code", "2  Passphrase", "3  Confirm").forEachIndexed { i, label ->
                HaloChip(label, selected = i == step, tint = if (i < step) HaloColors.Green else HaloColors.Accent, icon = if (i < step) Icons.Filled.Check else null)
            }
        }
        Spacer(Modifier.height(12.dp))
        when (val p = pair) {
            is PairUi.Working -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp); Spacer(Modifier.width(10.dp))
                Text(p.what, color = HaloColors.Text2, fontSize = 13.sp, modifier = Modifier.testTag("pair.working"))
            }
            is PairUi.NeedsPassphrase -> {
                Text("Paired with ${p.payload.firebaseConfig.projectID}.", color = HaloColors.Green, fontSize = 13.sp, modifier = Modifier.testTag("pair.accepted"))
                p.hostWarning?.let { Spacer(Modifier.height(6.dp)); Text(it, color = HaloColors.Amber, fontSize = 12.sp, modifier = Modifier.testTag("pair.hostWarning")) }
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(passphrase, { passphrase = it }, singleLine = true, label = { Text("Encryption passphrase") }, colors = haloFieldColors(),
                    visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth().testTag("pair.passphrase"),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    HaloPrimaryButton("Connect", { vm.connect(p.payload, passphrase) }, Modifier.testTag("pair.connect"))
                    HaloGhostButton("Back", { passphrase = ""; vm.cancelPairing() })
                }
            }
            is PairUi.NeedsConfirmation -> {
                Text("Paired with ${p.payload.firebaseConfig.projectID}.", color = HaloColors.Green, fontSize = 13.sp, modifier = Modifier.testTag("pair.accepted"))
                Spacer(Modifier.height(8.dp))
                Text(PairingConfirmation.NOTICE, color = HaloColors.Amber, fontSize = 12.sp, modifier = Modifier.testTag("pair.notice"))
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(confirmation, { confirmation = it }, singleLine = true, label = { Text("Type the passphrase again") }, colors = haloFieldColors(),
                    visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth().testTag("pair.confirm"),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                p.error?.let { Spacer(Modifier.height(6.dp)); Text(it, color = HaloColors.Red, fontSize = 12.sp, modifier = Modifier.testTag("pair.error")) }
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    HaloPrimaryButton("Confirm", { vm.confirm(confirmation) }, Modifier.testTag("pair.confirmButton"), enabled = confirmation.isNotEmpty())
                    HaloGhostButton("Back", { passphrase = ""; confirmation = ""; vm.cancelPairing() })
                }
            }
            else -> {
                OutlinedTextField(code, { code = it }, label = { Text("Pairing code") }, minLines = 2, maxLines = 4, colors = haloFieldColors(),
                    modifier = Modifier.fillMaxWidth().testTag("pair.code"))
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.horizontalScroll(rememberScrollState())) {
                    HaloPrimaryButton("Pair", { vm.submitCode(code) }, Modifier.testTag("pair.submit"), enabled = code.isNotBlank())
                    HaloGhostButton("Scan QR", { scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan the pairing code on your Mac").setBeepEnabled(false).setOrientationLocked(false)) }, Modifier.testTag("pair.scan"))
                    HaloGhostButton("Paste", { app.halo.mobile.cloud.ClipboardController.readClipboard(ctx)?.let { code = it } })
                }
                (p as? PairUi.Failed)?.let { Spacer(Modifier.height(8.dp)); Text(it.why, color = HaloColors.Red, fontSize = 12.sp, modifier = Modifier.testTag("pair.error")) }
            }
        }
    }
}

// ── Messages ───────────────────────────────────────────────────────────────────────────────────

private val SMS_PERMISSIONS = arrayOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS, Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_PHONE_NUMBERS)

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
/** The Messages tab: sync state + a utility inbox (sender, preview, time, line chips, one-tap OTP copy). Behaviour of the sync controls is unchanged. */
@Composable
fun SmsScreen(vm: CloudViewModel) {
    val profile by vm.profile.collectAsStateWithLifecycle()
    val problem by vm.profileProblem.collectAsStateWithLifecycle()
    val enabled by vm.smsEnabled.collectAsStateWithLifecycle()
    val lines by vm.lines.collectAsStateWithLifecycle()
    val syncing by vm.syncing.collectAsStateWithLifecycle()
    val notice by vm.notice.collectAsStateWithLifecycle()
    val warning by vm.warning.collectAsStateWithLifecycle()
    val tick by vm.syncTick.collectAsStateWithLifecycle()          // re-read the last-sync facts after each run
    val ctx = LocalContext.current
    fun granted(p: String) = ContextCompat.checkSelfPermission(ctx, p) == PackageManager.PERMISSION_GRANTED
    var canRead by remember { mutableStateOf(granted(Manifest.permission.READ_SMS)) }
    var canSeeSims by remember { mutableStateOf(granted(Manifest.permission.READ_PHONE_STATE)) }
    var resume by remember { mutableIntStateOf(0) }
    val askPermissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        canRead = granted(Manifest.permission.READ_SMS); canSeeSims = granted(Manifest.permission.READ_PHONE_STATE)
        if (canRead) { vm.setSmsEnabled(true); vm.refreshLines() }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        canRead = granted(Manifest.permission.READ_SMS); canSeeSims = granted(Manifest.permission.READ_PHONE_STATE); resume++
        if (profile != null) vm.refreshLines() else if (problem != null) vm.refreshProfile()
    }
    val syncSent by vm.syncSent.collectAsStateWithLifecycle()
    val removalPending by vm.sentRemovalPending.collectAsStateWithLifecycle()
    var confirmSentOn by remember { mutableStateOf(false) }
    var confirmSentOff by remember { mutableStateOf(false) }
    var allow by remember { mutableStateOf(vm.prefs.allow.joinToString(", ")) }
    var deny by remember { mutableStateOf(vm.prefs.deny.joinToString(", ")) }
    var lineFilter by rememberSaveable { mutableIntStateOf(ALL_LINES) }
    var copied by remember { mutableStateOf<String?>(null) }
    var messages by remember { mutableStateOf<List<LocalMessage>>(emptyList()) }
    LaunchedEffect(canRead, tick, resume) { messages = if (canRead) withContext(Dispatchers.IO) { LocalInbox.recent(ctx, 60) } else emptyList() }

    HaloScreen(HaloCopy.MESSAGES_TITLE, subtitle = if (profile != null && enabled && canRead) "Syncing to your Mac" else null) {
        if (profile == null) {
            if (problem != null) ProfileProblemCard(vm, problem!!)
            else PairingPanel(vm, "Pair this phone with your Mac to sync your text messages to the Halo console. Everything is encrypted on the phone before it leaves.")
            return@HaloScreen
        }
        warning?.let { HaloBanner(it) }

        // Sync card: the toggle, the last-sync fact, the two actions.
        HaloCard(accentTop = if (enabled && canRead) (if (vm.prefs.lastSyncError != null) HaloColors.Red else HaloColors.Green) else null) {
            HaloToggleRow(HaloCopy.SYNC_TO_MAC, enabled && canRead, { on ->
                if (!on) vm.setSmsEnabled(false) else if (canRead) vm.setSmsEnabled(true) else askPermissions.launch(SMS_PERMISSIONS)
            }, subtitle = if (canRead) "Inbox only, encrypted" else HaloCopy.NEEDS_PERMISSION, info = if (canRead) HaloCopy.INFO_SMS_SYNC else HaloCopy.INFO_SMS_PERMISSION, switchTag = Modifier.testTag("sms.toggle"))
            if (!canRead) {
                Spacer(Modifier.height(10.dp))
                HaloPrimaryButton(HaloCopy.ALLOW_SMS, { askPermissions.launch(SMS_PERMISSIONS) }, Modifier.fillMaxWidth().testTag("sms.grant"), icon = Icons.Filled.Lock)
            }
            if (enabled && canRead) {
                val prefs = vm.prefs
                Spacer(Modifier.height(8.dp))
                val last = prefs.lastSyncAt
                Row(verticalAlignment = Alignment.CenterVertically) {
                    HaloStatusBadge(if (prefs.lastSyncError != null) "Error" else if (last == 0L) "Not yet" else "Synced", if (prefs.lastSyncError != null) HaloColors.Red else if (last == 0L) HaloColors.Text3 else HaloColors.Green, icon = if (prefs.lastSyncError == null && last != 0L) Icons.Filled.Check else null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (last == 0L) "Waiting for the first sync" else DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(last)) + " · " + prefs.lastSyncSummary,
                        color = HaloColors.Text2, fontSize = 12.sp, modifier = Modifier.weight(1f).testTag("sms.last"))
                }
                prefs.lastSyncError?.let { Spacer(Modifier.height(4.dp)); Text(it, color = HaloColors.Red, fontSize = 12.sp, modifier = Modifier.testTag("sms.error")) }
                notice?.let { Spacer(Modifier.height(4.dp)); Text(it, color = HaloColors.Text2, fontSize = 12.sp, modifier = Modifier.testTag("sms.notice")) }
                val skipped = prefs.quarantinedCount
                if (skipped > 0) {
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        HaloStatusBadge(if (skipped == 1) "1 couldn't be synced" else "$skipped couldn't be synced", HaloColors.Amber, icon = Icons.Filled.Warning, modifier = Modifier.weight(1f, fill = false).testTag("sms.skipped"))
                        Spacer(Modifier.weight(1f))
                        HaloGhostButton(HaloCopy.RETRY_SKIPPED, { vm.retrySkipped() }, Modifier.testTag("sms.retrySkipped"), enabled = !syncing, tint = HaloColors.Amber)
                    }
                }
                Spacer(Modifier.height(8.dp))
                HaloToggleRow(HaloCopy.SENT_TITLE, syncSent, { on -> if (on) confirmSentOn = true else confirmSentOff = true },
                    subtitle = if (syncSent) HaloCopy.SENT_ON else if (removalPending) HaloCopy.SENT_REMOVING else HaloCopy.SENT_OFF,
                    info = HaloCopy.INFO_SENT_SYNC, switchTag = Modifier.testTag("sms.sent.toggle"), modifier = Modifier.testTag("sms.sent.row"))
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    HaloPrimaryButton(HaloCopy.SYNC_NOW, { vm.syncNow(reconcile = true) }, Modifier.testTag("sms.syncNow"), icon = Icons.Filled.Refresh, loading = syncing)
                    HaloGhostButton(HaloCopy.OLDER_HISTORY, { vm.extendHistory(365) }, enabled = !syncing)
                }
            }
        }

        // The inbox: a utility list, not a log.
        if (canRead) {
            HaloSectionHeader("Inbox", info = HaloCopy.INFO_OTP)
            if (lines.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.horizontalScroll(rememberScrollState())) {
                HaloChip(HaloCopy.ALL_LINES, selected = lineFilter == ALL_LINES, onClick = { lineFilter = ALL_LINES }, modifier = Modifier.testTag("sms.filter.all"))
                lines.forEach { l -> HaloChip(l.line.label.ifBlank { "SIM ${l.line.subscriptionId}" }, selected = lineFilter == l.line.subscriptionId, onClick = { lineFilter = l.line.subscriptionId }, modifier = Modifier.testTag("sms.filter.${l.line.subscriptionId}")) }
            }
            val shown = messages.filter { lineFilter == ALL_LINES || it.subId == lineFilter }.take(25)
            copied?.let { Text(it, style = HaloType.Caption, color = HaloColors.Green, modifier = Modifier.testTag("sms.copied")) }
            if (shown.isEmpty()) HaloCard { HaloEmptyState(Icons.Filled.Email, HaloCopy.NO_MESSAGES, subtitle = HaloCopy.NO_MESSAGES_SUB) }
            else HaloCard(contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 14.dp, vertical = 6.dp)) {
                val now = System.currentTimeMillis()
                shown.forEach { m -> MessageRow(m, now, lines.firstOrNull { it.line.subscriptionId == m.subId }?.line?.label?.takeIf { lines.size > 1 }) { code ->
                    app.halo.mobile.cloud.ClipboardController.copyToClipboard(ctx, ClipItem("otp-${m.id}", code, "text", "Messages", System.currentTimeMillis(), received = false))
                    copied = "Code copied"
                } }
            }
        }

        HaloSectionHeader(HaloCopy.SIM_LINES, info = if (!canSeeSims) HaloCopy.INFO_NO_SIM_NAMES else null)
        if (enabled && canRead) lines.forEach { LineCard(it, vm) }
        else HaloCard { Text("Turn on sync to choose lines.", style = HaloType.Caption, color = HaloColors.Text2) }

        if (enabled && canRead) {
            HaloSectionHeader(HaloCopy.WHO_TO_SYNC, info = HaloCopy.INFO_FILTERS)
            HaloCard {
                OutlinedTextField(allow, { allow = it }, label = { Text("Only these senders (optional)") }, colors = haloFieldColors(), modifier = Modifier.fillMaxWidth().testTag("sms.allow"), minLines = 1, maxLines = 3)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(deny, { deny = it }, label = { Text("Never these senders") }, colors = haloFieldColors(), modifier = Modifier.fillMaxWidth().testTag("sms.deny"), minLines = 1, maxLines = 3)
                Spacer(Modifier.height(8.dp))
                HaloGhostButton("Save filters", { vm.setFilters(allow, deny) }, icon = Icons.Filled.Check)
            }
        }
    }

    if (confirmSentOn) AlertDialog(
        onDismissRequest = { confirmSentOn = false }, containerColor = HaloColors.Surface,
        title = { Text(HaloCopy.SENT_CONFIRM_ON_TITLE, color = HaloColors.Text) },
        text = { Text("Your sent messages from the last ${vm.prefs.backfillDays} days will be uploaded, encrypted.", color = HaloColors.Text2) },
        confirmButton = { HaloPrimaryButton("Turn on", { confirmSentOn = false; vm.enableSentSync() }, Modifier.testTag("sms.sent.confirmOn")) },
        dismissButton = { HaloGhostButton("Cancel", { confirmSentOn = false }) },
    )
    if (confirmSentOff) AlertDialog(
        onDismissRequest = { confirmSentOff = false }, containerColor = HaloColors.Surface,
        title = { Text(HaloCopy.SENT_CONFIRM_OFF_TITLE, color = HaloColors.Text) },
        text = { Text("Delete the sent messages already uploaded? They will disappear from your Mac. Messages on this phone are not touched.", color = HaloColors.Text2) },
        confirmButton = { HaloPrimaryButton("Stop and delete", { confirmSentOff = false; vm.disableSentSync(removeUploaded = true) }, Modifier.testTag("sms.sent.removeUploaded")) },
        dismissButton = { HaloGhostButton("Stop, keep", { confirmSentOff = false; vm.disableSentSync(removeUploaded = false) }, Modifier.testTag("sms.sent.keepUploaded")) },
    )
}

private const val ALL_LINES = Int.MIN_VALUE

@Composable
private fun MessageRow(m: LocalMessage, now: Long, lineLabel: String?, onCopyCode: (String) -> Unit) {
    val otp = remember(m.id) { OtpCode.find(m.body) }
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag("sms.row")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            HaloAvatar(m.address.ifBlank { "?" }, tint = if (otp != null) HaloColors.Green else HaloColors.Accent)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(m.address.ifBlank { "Unknown" }, color = HaloColors.Text, fontSize = 15.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                    if (!m.read) { Spacer(Modifier.width(6.dp)); Box(Modifier.size(8.dp).background(HaloColors.Accent, CircleShape).testTag("sms.unread")) }
                    if (lineLabel != null) { Spacer(Modifier.width(6.dp)); HaloStatusBadge(lineLabel, HaloColors.Text2) }
                }
                Text(m.body.replace('\n', ' '), color = HaloColors.Text2, fontSize = 13.sp, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
            }
            Spacer(Modifier.width(8.dp))
            Text(RelativeTime.compact(now, m.dateMs), color = HaloColors.Text3, style = HaloType.Caption)
        }
        if (otp != null) {
            Spacer(Modifier.height(6.dp))
            HaloChip("Copy $otp", tint = HaloColors.Green, icon = Icons.Filled.Check, modifier = Modifier.padding(start = 52.dp).testTag("sms.otp"), onClick = { onCopyCode(otp) })
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
                Text(l.line.label, color = HaloColors.Text, fontSize = 15.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium)
                Text("${l.line.ownNumber.ifBlank { "number not provided" }} · ${l.line.carrier}", color = HaloColors.Text2, fontSize = 12.sp)
            }
            HaloIconButton(Icons.Filled.Create, if (editing) "Close editor" else "Rename ${l.line.label}", { editing = !editing })
            HaloSwitch(l.enabled, { vm.setLineEnabled(l.line.subscriptionId, it) }, Modifier.testTag("sms.line.${l.line.subscriptionId}"))
        }
        if (editing) {
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(label, { label = it }, singleLine = true, label = { Text("Name (e.g. Personal)") }, colors = haloFieldColors(), modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(6.dp))
            OutlinedTextField(number, { number = it }, singleLine = true, label = { Text("This SIM's phone number") }, colors = haloFieldColors(), modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(8.dp))
            HaloGhostButton("Save", { vm.saveLine(l.line.subscriptionId, label, number); editing = false }, icon = Icons.Filled.Check)
        }
    }
}

// ── Clipboard ──────────────────────────────────────────────────────────────────────────────────

@Composable
fun ClipboardScreen(vm: CloudViewModel) {
    val profile by vm.profile.collectAsStateWithLifecycle()
    val problem by vm.profileProblem.collectAsStateWithLifecycle()
    val historyKeyLost by vm.historyKeyLost.collectAsStateWithLifecycle()
    val enabled by vm.clipEnabled.collectAsStateWithLifecycle()
    val filter by vm.clipFilter.collectAsStateWithLifecycle()
    val history by vm.history.collectAsStateWithLifecycle()
    val historyWarning by vm.historyWarning.collectAsStateWithLifecycle()
    val notice by vm.clipNotice.collectAsStateWithLifecycle()
    val status by vm.clipStatus.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    var accessibility by remember { mutableStateOf(vm.accessibilityEnabled()) }
    var confirmPurge by remember { mutableStateOf(false) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { accessibility = vm.accessibilityEnabled(); vm.retryHistory(); if (profile == null && problem != null) vm.refreshProfile() }

    HaloScreen(HaloCopy.CLIPBOARD_TITLE, subtitle = if (profile != null) (if (enabled) "Syncing with your Mac" else "Sync is off") else null) {
        if (profile == null) {
            if (problem != null) ProfileProblemCard(vm, problem!!)
            else PairingPanel(vm, "Pair this phone with your Mac to share your clipboard between them. Copies are encrypted before they leave.")
            return@HaloScreen
        }
        val tools: ToolsViewModel = viewModel()
        HaloPrimaryButton(HaloCopy.SEND_CURRENT, vm::sendClipboardNow, Modifier.fillMaxWidth().testTag("clip.sendNow"), icon = Icons.Filled.Send, enabled = enabled)
        if (status.isNotBlank()) Text(status, color = HaloColors.Text2, fontSize = 12.sp, modifier = Modifier.testTag("clip.status"))
        notice?.let { Text(it, color = HaloColors.Text2, fontSize = 12.sp, modifier = Modifier.testTag("clip.notice")) }

        HaloCard {
            HaloToggleRow(HaloCopy.SYNC_CLIPBOARD, enabled, vm::setClipboardEnabled, subtitle = "Text and links", info = HaloCopy.INFO_CLIPBOARD_SYNC, switchTag = Modifier.testTag("clip.toggle"))
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(HaloCopy.AUTO_CAPTURE, color = HaloColors.Text, fontSize = 15.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium)
                    HaloStatusBadge(if (accessibility) "On" else "Off", if (accessibility) HaloColors.Green else HaloColors.Text2, Modifier.padding(top = 4.dp).testTag("clip.a11y"), icon = if (accessibility) Icons.Filled.Check else null)
                }
                HaloInfoButton(HaloCopy.INFO_AUTOMATIC_CAPTURE)
                if (!accessibility) HaloGhostButton("Open settings", { ctx.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }, Modifier.testTag("clip.openA11y"))
            }
            HaloToggleRow(HaloCopy.KEEP_SECRETS, filter, vm::setClipboardFilter, subtitle = "Off by default", info = HaloCopy.INFO_SECRETS)
        }

        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { HaloSectionHeader(HaloCopy.HISTORY) }
            if (history.isNotEmpty()) HaloIconButton(Icons.Filled.Delete, "Purge synced clipboard", { confirmPurge = true }, tint = HaloColors.Text2)
        }
        historyWarning?.let { HaloBanner(it, textModifier = Modifier.testTag("clip.storageWarning")) }
        if (historyKeyLost) HaloGhostButton("Reset clipboard history", vm::resetHistory, Modifier.testTag("clip.resetHistory"), tint = HaloColors.Amber)
        if (history.isEmpty()) HaloCard { HaloEmptyState(Icons.Filled.Send, HaloCopy.NOTHING_SYNCED, subtitle = HaloCopy.NOTHING_SYNCED_SUB) }
        history.take(50).forEach { ClipCard(it, onCopy = { vm.copy(it) }, onSend = { vm.sendClipText(it.text) }, onTransform = { tools.transformText(it.text) }) }
    }
    if (confirmPurge) androidx.compose.material3.AlertDialog(
        onDismissRequest = { confirmPurge = false }, containerColor = HaloColors.Surface,
        title = { Text("Remove synced clipboard?", color = HaloColors.Text) },
        text = { Text("This deletes every synced clipboard item from your cloud and from this phone. Your Mac keeps its own history.", color = HaloColors.Text2) },
        confirmButton = { HaloPrimaryButton("Remove", { vm.purgeClipboard(); confirmPurge = false }, Modifier.testTag("clip.purgeConfirm")) },
        dismissButton = { HaloGhostButton("Cancel", { confirmPurge = false }) },
    )
}

/** A typed clipboard card: accent bar + badge by kind (link cyan, code purple, text accent), copy and send-to-Mac as icon buttons. */
@Composable
private fun ClipCard(item: ClipItem, onCopy: () -> Unit, onSend: () -> Unit, onTransform: () -> Unit) {
    val kind = remember(item.id) { ClipKind.of(item.kind, item.text) }
    val tint = when (kind) { ClipKind.URL -> HaloColors.Cyan; ClipKind.CODE -> HaloColors.Purple; ClipKind.TEXT -> HaloColors.Accent }
    HaloCard(Modifier.testTag("clip.item"), accentTop = tint) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            HaloStatusBadge(kind.label, tint)
            Spacer(Modifier.width(8.dp))
            Text("${if (item.received) "From" else "Sent from"} ${item.from} · ${RelativeTime.compact(System.currentTimeMillis(), item.atMs)}", color = HaloColors.Text2, style = HaloType.Caption, maxLines = 1, modifier = Modifier.weight(1f))
        }
        Spacer(Modifier.height(8.dp))
        Text(item.text, color = if (kind == ClipKind.URL) HaloColors.Cyan else HaloColors.Text, style = if (kind == ClipKind.CODE) HaloType.Mono else HaloType.Body, maxLines = 4, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            HaloGhostButton("Transform…", onTransform, Modifier.testTag("clip.transform"), tint = tint)
            HaloIconButton(Icons.Filled.Send, "Send to Mac", onSend, tint = tint)
            HaloIconButton(HaloIcons.Copy, "Copy", onCopy, tint = tint, filled = true)
        }
    }
}

// ── Settings block ─────────────────────────────────────────────────────────────────────────────

@Composable
fun CloudSettingsCard(vm: CloudViewModel) {
    val profile by vm.profile.collectAsStateWithLifecycle()
    val problem by vm.profileProblem.collectAsStateWithLifecycle()
    var name by remember { mutableStateOf(vm.deviceName) }
    var confirm by remember { mutableStateOf(false) }
    HaloCard {
        HaloSectionHeader("Halo cloud")
        val p = profile
        if (p == null && problem != null) ProfileProblemCard(vm, problem!!)
        else if (p == null) Text("Not paired. Pair from Messages or Clipboard.", color = HaloColors.Text2, fontSize = 13.sp)
        else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                HaloStatusBadge("Connected", HaloColors.Green, icon = Icons.Filled.Check)
                Spacer(Modifier.width(8.dp))
                Text("Connected to ${p.config.projectID}", color = HaloColors.Text, fontSize = 13.sp, modifier = Modifier.weight(1f).testTag("settings.cloud"))
            }
            Text("Signed in as ${p.auth.email}", color = HaloColors.Text2, fontSize = 12.sp)
            Spacer(Modifier.height(10.dp))
            OutlinedTextField(name, { name = it }, singleLine = true, label = { Text("This phone's name on your Mac") }, colors = haloFieldColors(), modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                HaloGhostButton("Save name", { vm.deviceName = name }, enabled = name.isNotBlank() && name.trim() != vm.deviceName)
                HaloGhostButton("Disconnect", { confirm = true }, Modifier.testTag("settings.disconnect"), tint = HaloColors.Red)
                HaloInfoButton(HaloCopy.INFO_DISCONNECT)
            }
        }
    }
    if (confirm) androidx.compose.material3.AlertDialog(
        onDismissRequest = { confirm = false }, containerColor = HaloColors.Surface,
        title = { Text("Disconnect this phone?", color = HaloColors.Text) },
        text = { Text("SMS and clipboard sync stop. You can pair again any time with a new code from your Mac.", color = HaloColors.Text2) },
        confirmButton = { HaloPrimaryButton("Disconnect", { vm.disconnect(); confirm = false }) },
        dismissButton = { HaloGhostButton("Cancel", { confirm = false }) },
    )
}

/**
 * Shown instead of the pairing panel when a saved connection exists but cannot be opened. Pairing again would
 * overwrite it, so while the failure may be temporary the only action is "Try again" (and the screen retries on resume).
 */
@Composable
fun ProfileProblemCard(vm: CloudViewModel, problem: ProfileProblem) {
    var confirm by remember { mutableStateOf(false) }
    when (problem) {
        ProfileProblem.UNAVAILABLE -> HaloBanner("Cloud profile temporarily unavailable — will retry.", info = HaloCopy.INFO_PROFILE_UNAVAILABLE,
            textModifier = Modifier.testTag("cloud.profileUnavailable"), actionLabel = "Try again", onAction = vm::refreshProfile, actionTag = Modifier.testTag("cloud.profileRetry"))
        ProfileProblem.KEY_LOST -> HaloCard(accentTop = HaloColors.Amber) {
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Filled.Warning, null, tint = HaloColors.Amber, modifier = Modifier.padding(top = 2.dp).size(18.dp)); Spacer(Modifier.width(10.dp))
                Text("This phone's saved Halo connection can't be unlocked.", color = HaloColors.Text, fontSize = 14.sp, modifier = Modifier.weight(1f).testTag("cloud.profileKeyLost"))
                HaloInfoButton(HaloCopy.INFO_KEY_LOST)
            }
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                HaloGhostButton("Try again", vm::refreshProfile)
                HaloPrimaryButton("Reset and pair again", { confirm = true }, Modifier.testTag("cloud.profileReset"))
            }
        }
    }
    if (confirm) androidx.compose.material3.AlertDialog(
        onDismissRequest = { confirm = false }, containerColor = HaloColors.Surface,
        title = { Text("Forget the unreadable connection?", color = HaloColors.Text) },
        text = { Text("This removes the saved connection from this phone so you can pair again. It cannot be undone, but it could not be opened anyway.", color = HaloColors.Text2) },
        confirmButton = { HaloPrimaryButton("Reset", { vm.resetLostProfile(); confirm = false }) },
        dismissButton = { HaloGhostButton("Cancel", { confirm = false }) },
    )
}
