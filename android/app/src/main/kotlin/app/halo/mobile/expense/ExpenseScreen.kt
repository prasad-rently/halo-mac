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
import androidx.compose.material3.Button
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
import app.halo.mobile.Halo
import app.halo.mobile.HaloCard
import app.halo.mobile.SectionLabel
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
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted = canRead(); if (granted) vm.setEnabled(true) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Spending", color = Halo.Text, fontSize = 22.sp, fontWeight = FontWeight.Bold)

        if (!ui.enabled || !granted) {
            HaloCard {
                SectionLabel("Track spending from your bank SMS")
                Spacer(Modifier.height(8.dp))
                Text("Halo reads the bank and UPI messages already on this phone and adds them up by month and category. It never leaves the phone: the amounts are stored encrypted here, are not uploaded to your cloud, and nothing in this feature uses the network. OTP, offer and balance messages are ignored.",
                    color = Halo.Text2, fontSize = 13.sp)
                Spacer(Modifier.height(10.dp))
                Button(onClick = { if (granted) vm.setEnabled(true) else ask.launch(SMS_READ) }, modifier = Modifier.testTag("expense.enable")) {
                    Text(if (granted) "Turn on" else "Allow SMS access and turn on")
                }
            }
            return@Column
        }

        val s = ui.summary
        // Month header + scan controls
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = { vm.stepMonth(-1) }, modifier = Modifier.testTag("expense.prev")) { Text("‹") }
            Text("${ui.month.month.getDisplayName(TextStyle.FULL, Locale.getDefault())} ${ui.month.year}", color = Halo.Text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("expense.month"))
            TextButton(onClick = { vm.stepMonth(1) }, modifier = Modifier.testTag("expense.next")) { Text("›") }
        }

        HaloCard {
            SectionLabel("Spent this month")
            Spacer(Modifier.height(4.dp))
            Text(inr(s?.spent ?: 0.0), color = Halo.Text, fontSize = 32.sp, fontWeight = FontWeight.Bold, modifier = Modifier.testTag("expense.total"))
            Spacer(Modifier.height(4.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Received ${inr(s?.received ?: 0.0)}", color = Halo.Green, fontSize = 12.sp, modifier = Modifier.testTag("expense.received"))
                Text("Net ${inr(s?.net ?: 0.0)}", color = Halo.Text2, fontSize = 12.sp)
            }
            Spacer(Modifier.height(4.dp))
            Text("Transfers between your own accounts and duplicate alerts are not counted.", color = Halo.Text3, fontSize = 11.sp)
        }

        HaloCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (ui.scanning) { CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)) }
                Text(when { ui.scanning -> "Reading messages…"; ui.error != null -> ui.error!!; else -> ui.status ?: "Up to date" },
                    color = if (ui.error != null) Halo.Red else Halo.Text2, fontSize = 12.sp, modifier = Modifier.weight(1f).testTag("expense.status"))
                if (ui.scanning) OutlinedButton(onClick = { vm.cancelScan() }, modifier = Modifier.testTag("expense.cancel")) { Text("Stop") }
                else OutlinedButton(onClick = { vm.scan() }, modifier = Modifier.testTag("expense.scan")) { Text("Scan") }
            }
            if ((s?.unreadableCount ?: 0) > 0) {
                Spacer(Modifier.height(6.dp))
                Text("${s!!.unreadableCount} message${if (s.unreadableCount == 1) "" else "s"} looked like a transaction but had no readable amount.", color = Halo.Amber, fontSize = 11.sp, modifier = Modifier.testTag("expense.unreadable"))
            }
        }

        // By category
        val cats = s?.byCategory.orEmpty()
        HaloCard {
            SectionLabel("By category")
            Spacer(Modifier.height(8.dp))
            if (cats.isEmpty()) Text("No spending found for this month.", color = Halo.Text3, fontSize = 13.sp, modifier = Modifier.testTag("expense.nocategories"))
            val max = cats.maxOfOrNull { it.second } ?: 1.0
            cats.forEach { (name, amt) ->
                Column(Modifier.padding(vertical = 4.dp).testTag("expense.cat.$name")) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(name, color = Halo.Text, fontSize = 13.sp); Text(inr(amt), color = Halo.Text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Spacer(Modifier.height(3.dp))
                    Box(Modifier.fillMaxWidth().height(4.dp).background(Halo.Surface2, RoundedCornerShape(2.dp))) {
                        Box(Modifier.fillMaxWidth((amt / max).toFloat().coerceIn(0.02f, 1f)).height(4.dp).background(Halo.Accent, RoundedCornerShape(2.dp)))
                    }
                }
            }
        }

        // Recent
        HaloCard {
            SectionLabel("Recent")
            Spacer(Modifier.height(6.dp))
            val recent = s?.recent.orEmpty()
            if (recent.isEmpty()) Text("Nothing to show.", color = Halo.Text3, fontSize = 13.sp)
            recent.forEach { t -> TxnRow(t, onExclude = { vm.exclude(t.id) }) }
        }

        if (ui.excluded.isNotEmpty()) {
            HaloCard {
                SectionLabel("Excluded (${ui.excluded.size})")
                Spacer(Modifier.height(6.dp))
                ui.excluded.forEach { t -> TxnRow(t, actionLabel = "Restore", onExclude = { vm.unexclude(t.id) }, dim = true) }
            }
        }

        if (ui.lines.size > 1) {
            HaloCard {
                SectionLabel("SIMs included")
                ui.lines.forEach { l ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("${l.line.label} · ${l.line.carrier}", color = Halo.Text, fontSize = 13.sp, modifier = Modifier.weight(1f))
                        Switch(checked = l.enabled, onCheckedChange = { vm.setLineEnabled(l.line.subscriptionId, it) }, modifier = Modifier.testTag("expense.sim.${l.line.subscriptionId}"))
                    }
                }
                Text("The sender allow/deny list from SMS settings also applies.", color = Halo.Text3, fontSize = 11.sp)
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { vm.scanOlder(365) }, enabled = !ui.scanning, modifier = Modifier.testTag("expense.older")) { Text("Scan older (1 year)") }
            TextButton(onClick = { vm.wipe() }, modifier = Modifier.testTag("expense.wipe")) { Text("Delete & turn off", color = Halo.Red) }
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun TxnRow(t: ParsedTransaction, onExclude: () -> Unit, actionLabel: String = "Exclude", dim: Boolean = false) {
    val whenText = Instant.ofEpochMilli(t.dateMs).atZone(ZoneId.systemDefault()).format(dayFmt)
    val sign = if (t.direction == Direction.CREDIT) "+" else "−"
    Row(Modifier.fillMaxWidth().padding(vertical = 5.dp).testTag("expense.row.${t.id}"), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(t.merchant?.takeIf { it.isNotBlank() } ?: t.sender, color = if (dim) Halo.Text3 else Halo.Text, fontSize = 13.sp, maxLines = 1)
            val flags = buildList { add(t.category); if (t.isTransfer) add("self-transfer, not counted"); if (t.isDuplicate) add("duplicate, not counted") }.joinToString(" · ")
            Text("$flags · $whenText", color = Halo.Text3, fontSize = 11.sp, maxLines = 2)
        }
        Text("$sign${inr(t.amount)}", color = if (dim) Halo.Text3 else if (t.direction == Direction.CREDIT) Halo.Green else Halo.Text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        TextButton(onClick = onExclude, modifier = Modifier.testTag("expense.action.${t.id}")) { Text(actionLabel, fontSize = 12.sp) }
    }
}
