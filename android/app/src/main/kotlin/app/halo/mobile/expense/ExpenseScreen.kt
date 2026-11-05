package app.halo.mobile.expense

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.halo.cloud.expense.Direction
import app.halo.cloud.expense.ParsedTransaction
import app.halo.mobile.design.*
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

// F-056 FR-E4: month total, by-category list, recent transactions, "exclude this". Local-only — the amounts never
// leave the phone and are stored sealed (see ExpenseRuntime). NOT verified on an emulator or device (JVM-only session).

private val SMS_READ = arrayOf(Manifest.permission.READ_SMS, Manifest.permission.READ_PHONE_STATE)
private val INR: NumberFormat = NumberFormat.getCurrencyInstance(Locale("en", "IN")).apply { maximumFractionDigits = 2; minimumFractionDigits = 0 }
private fun inr(v: Double) = INR.format(v)
private val dayFmt = DateTimeFormatter.ofPattern("d MMM, h:mm a", Locale.getDefault())

@Composable
fun ExpenseScreen(vm: ExpenseViewModel = viewModel()) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    fun canRead() = ContextCompat.checkSelfPermission(ctx, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(canRead()) }
    var confirmWipe by remember { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted = canRead(); if (granted) vm.setEnabled(true) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = HaloSpacing.ScreenH, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(HaloSpacing.Gap)) {
        if (!ui.enabled || !granted) {
            HaloCard {
                HaloEmptyState(Icons.Filled.Lock, "Track spending", subtitle = "From bank SMS, on this phone only", actionLabel = if (granted) "Turn on" else "Allow SMS and turn on",
                    onAction = { if (granted) vm.setEnabled(true) else ask.launch(SMS_READ) }, tint = HaloColors.Green, modifier = Modifier.testTag("expense.enable"))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) { HaloInfoButton(EXPENSE_INFO) }
            }
            return@Column
        }

        val s = ui.summary
        // Month stepper
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            HaloIconButton(Icons.Filled.ArrowBack, "Previous month", { vm.stepMonth(-1) }, Modifier.testTag("expense.prev"))
            Text("${ui.month.month.getDisplayName(TextStyle.FULL, Locale.getDefault())} ${ui.month.year}", color = HaloColors.Text, style = HaloType.Title, modifier = Modifier.testTag("expense.month"))
            HaloIconButton(Icons.Filled.ArrowForward, "Next month", { vm.stepMonth(1) }, Modifier.testTag("expense.next"))
        }

        HaloCard(accentTop = HaloColors.Green) {
            HaloSectionHeader("Spent this month", info = EXPENSE_INFO)
            Text(inr(s?.spent ?: 0.0), color = HaloColors.Text, style = HaloType.Number.copy(fontSize = 34.sp), modifier = Modifier.testTag("expense.total"))
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Received ${inr(s?.received ?: 0.0)}", color = HaloColors.Green, style = HaloType.Caption, modifier = Modifier.testTag("expense.received"))
                Text("Net ${inr(s?.net ?: 0.0)}", color = HaloColors.Text2, style = HaloType.Caption)
            }
        }

        HaloCard {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (ui.scanning) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = HaloColors.Accent)
                Text(when { ui.scanning -> "Reading messages…"; ui.error != null -> ui.error!!; else -> ui.status ?: "Up to date" },
                    color = if (ui.error != null) HaloColors.Red else HaloColors.Text2, style = HaloType.Caption, modifier = Modifier.weight(1f).testTag("expense.status"))
                if (ui.scanning) HaloGhostButton("Stop", { vm.cancelScan() }, Modifier.testTag("expense.cancel"))
                else HaloGhostButton("Scan", { vm.scan() }, Modifier.testTag("expense.scan"), icon = Icons.Filled.Refresh)
            }
            if ((s?.unreadableCount ?: 0) > 0) {
                Spacer(Modifier.height(6.dp))
                HaloStatusBadge("${s!!.unreadableCount} unreadable", HaloColors.Amber, icon = Icons.Filled.Warning, modifier = Modifier.testTag("expense.unreadable"))
            }
        }

        // By category
        val cats = s?.byCategory.orEmpty()
        HaloSectionHeader("By category")
        HaloCard {
            if (cats.isEmpty()) Text("No spending found for this month.", color = HaloColors.Text2, style = HaloType.Caption, modifier = Modifier.testTag("expense.nocategories"))
            val max = cats.maxOfOrNull { it.second } ?: 1.0
            cats.forEach { (name, amt) ->
                Column(Modifier.padding(vertical = 5.dp).testTag("expense.cat.$name")) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(name, color = HaloColors.Text, fontSize = 14.sp); Text(inr(amt), color = HaloColors.Text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Spacer(Modifier.height(4.dp))
                    Box(Modifier.fillMaxWidth().height(5.dp).background(HaloColors.Surface, RoundedCornerShape(3.dp))) {
                        Box(Modifier.fillMaxWidth((amt / max).toFloat().coerceIn(0.02f, 1f)).height(5.dp).background(HaloColors.AccentGradient, RoundedCornerShape(3.dp)))
                    }
                }
            }
        }

        // Recent
        HaloSectionHeader("Recent")
        HaloCard {
            val recent = s?.recent.orEmpty()
            if (recent.isEmpty()) Text("Nothing to show.", color = HaloColors.Text2, style = HaloType.Caption)
            recent.forEach { t -> TxnRow(t, onExclude = { vm.exclude(t.id) }) }
        }

        if (ui.excluded.isNotEmpty()) {
            HaloSectionHeader("Excluded (${ui.excluded.size})")
            HaloCard { ui.excluded.forEach { t -> TxnRow(t, actionLabel = "Restore", onExclude = { vm.unexclude(t.id) }, dim = true) } }
        }

        if (ui.lines.size > 1) {
            HaloSectionHeader("SIMs included", info = HaloInfo("SIMs included", "The sender allow/deny list from Messages settings also applies."))
            HaloCard {
                ui.lines.forEach { l -> HaloToggleRow("${l.line.label} · ${l.line.carrier}", l.enabled, { vm.setLineEnabled(l.line.subscriptionId, it) }, switchTag = Modifier.testTag("expense.sim.${l.line.subscriptionId}")) }
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            HaloGhostButton("Scan older (1 year)", { vm.scanOlder(365) }, Modifier.testTag("expense.older"), enabled = !ui.scanning)
            HaloGhostButton("Delete & turn off", { confirmWipe = true }, Modifier.testTag("expense.wipe"), icon = Icons.Filled.Delete, tint = HaloColors.Red)
        }
        Spacer(Modifier.height(24.dp))
    }

    if (confirmWipe) AlertDialog(
        onDismissRequest = { confirmWipe = false }, containerColor = HaloColors.Surface,
        title = { Text("Delete spending data?", color = HaloColors.Text) },
        text = { Text("The spending data stored on this phone is deleted and tracking is turned off. Your messages are not touched.", color = HaloColors.Text2) },
        confirmButton = { HaloPrimaryButton("Delete", { confirmWipe = false; vm.wipe() }, Modifier.testTag("expense.wipe.confirm")) },
        dismissButton = { HaloGhostButton("Cancel", { confirmWipe = false }) },
    )
}

private val EXPENSE_INFO = HaloInfo("Spending from bank SMS",
    "Halo reads the bank and UPI messages already on this phone and adds them up by month and category. It never leaves the phone: the amounts are stored encrypted here, are not uploaded to your cloud, and nothing in this feature uses the network. OTP, offer and balance messages are ignored.",
    listOf("Transfers between your own accounts and duplicate alerts are not counted.", "Only messages you received are read; sent messages are never used."))

@Composable
private fun TxnRow(t: ParsedTransaction, onExclude: () -> Unit, actionLabel: String = "Exclude", dim: Boolean = false) {
    val whenText = Instant.ofEpochMilli(t.dateMs).atZone(ZoneId.systemDefault()).format(dayFmt)
    val sign = if (t.direction == Direction.CREDIT) "+" else "−"
    Row(Modifier.fillMaxWidth().padding(vertical = 5.dp).testTag("expense.row.${t.id}"), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(t.merchant?.takeIf { it.isNotBlank() } ?: t.sender, color = if (dim) HaloColors.Text3 else HaloColors.Text, fontSize = 14.sp, maxLines = 1)
            val flags = buildList { add(t.category); if (t.isTransfer) add("self-transfer, not counted"); if (t.isDuplicate) add("duplicate, not counted") }.joinToString(" · ")
            Text("$flags · $whenText", color = HaloColors.Text3, fontSize = 11.sp, maxLines = 2)
        }
        Text("$sign${inr(t.amount)}", color = if (dim) HaloColors.Text3 else if (t.direction == Direction.CREDIT) HaloColors.Green else HaloColors.Text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.width(6.dp))
        HaloGhostButton(actionLabel, onExclude, Modifier.testTag("expense.action.${t.id}"))
    }
}
