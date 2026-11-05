package app.halo.mobile.tools

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.viewmodel.compose.viewModel
import app.halo.mobile.Halo
import app.halo.mobile.design.HaloEmptyState
import app.halo.mobile.design.HaloIconButton
import app.halo.mobile.design.HaloInfo
import app.halo.mobile.design.HaloInfoSheet
import app.halo.mobile.design.HaloListRow
import app.halo.mobile.design.HaloPrimaryButton
import app.halo.mobile.design.HaloStatusBadge
import app.halo.mobile.HaloCard
import app.halo.mobile.SectionLabel
import app.halo.tools.NetworkState
import app.halo.tools.SpeedPlan
import app.halo.tools.SpeedResult
import app.halo.tools.SpeedTestGate
import java.text.DateFormat
import java.util.Date

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SpeedTestScreen() {
    val vm: ToolsViewModel = viewModel()
    val speed = vm.speed
    var net by remember { mutableStateOf(vm.networkState()) }
    var confirm by remember { mutableStateOf<String?>(null) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { net = vm.networkState() }       // re-read on every return to the screen: Wi-Fi -> mobile data changes the answer
    val phase = speed.phase
    // The test takes tens of seconds and a sleeping screen would pause it: hold the screen on only while it runs.
    LocalView.current.keepScreenOn = phase is ToolsViewModel.SpeedPhase.Running
    val plan = remember { SpeedPlan() }
    val gate = SpeedTestGate.decide(net, plan)

    var info by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HaloCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionLabel("Connection", Modifier.weight(1f))
                HaloIconButton(Icons.Filled.Info, "About Speed Test", { info = true }, Modifier.testTag("tools.speed.info"))
            }
            // The data-use disclosure stays on the main surface, as a chip: it is the thing to know before tapping Start.
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                HaloStatusBadge(if (net.connected) net.kind.label else "Offline", if (net.connected) Halo.Green else Halo.Red, Modifier.testTag("tools.speed.network"))
                HaloStatusBadge("Uses ~${plan.estimatedDataBytes / 1_000_000} MB", if (gate is SpeedTestGate.Confirm) Halo.Amber else Halo.Text2, Modifier.testTag("tools.speed.explain"))
                if (net.metered) HaloStatusBadge("Metered", Halo.Amber)
            }
            (gate as? SpeedTestGate.Blocked)?.let { Text("You're offline", color = Halo.Red, fontSize = 12.sp, modifier = Modifier.testTag("tools.speed.blocked")) }
            (gate as? SpeedTestGate.Confirm)?.let { Text("May use your data plan", color = Halo.Amber, fontSize = 12.sp, modifier = Modifier.testTag("tools.speed.metered")) }
            Spacer(Modifier.height(12.dp))
            when (phase) {
                is ToolsViewModel.SpeedPhase.Running -> HaloPrimaryButton("Cancel", speed::cancel, Modifier.fillMaxWidth().testTag("tools.speed.cancel"))
                else -> HaloPrimaryButton(if (phase is ToolsViewModel.SpeedPhase.Finished) "Run again" else "Start test", {
                    val g = SpeedTestGate.decide(vm.networkState().also { net = it }, plan)
                    when (g) { is SpeedTestGate.Go -> speed.start(); is SpeedTestGate.Confirm -> confirm = g.message; is SpeedTestGate.Blocked -> {} }
                }, Modifier.fillMaxWidth().testTag("tools.speed.start"), enabled = gate !is SpeedTestGate.Blocked)
            }
        }

        when (phase) {
            is ToolsViewModel.SpeedPhase.Running -> HaloCard {
                Text(phase.stage, color = Halo.Text2, fontSize = 13.sp, modifier = Modifier.testTag("tools.speed.stage"))
                Spacer(Modifier.height(8.dp))
                if (phase.fraction != null) LinearProgressIndicator(progress = { phase.fraction }, modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Download progress ${(phase.fraction * 100).toInt()} percent" })
                else LinearProgressIndicator(modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Working" })
                phase.liveMbps?.let { Spacer(Modifier.height(6.dp)); Text("%.1f Mbps".format(it), color = Halo.Accent, fontSize = 32.sp, fontWeight = FontWeight.Bold) }
            }
            is ToolsViewModel.SpeedPhase.Finished -> Results(phase.result, phase.atMs)
            ToolsViewModel.SpeedPhase.Idle -> {}
        }
    }

    if (info) HaloInfoSheet(HaloInfo("Speed Test", "Downloads about ${plan.downloadBytes / 1_000_000} MB and uploads about ${plan.uploadBytes / 1_000_000} MB over your current connection, and times 10 small requests for latency. It only runs when you tap Start.", listOf("Servers: Cloudflare's public speed endpoint (speed.cloudflare.com) and 1.1.1.1 — the same ones Halo on your Mac uses. Cloudflare sees your IP address, like any website. Only zero-filled test data is sent.", "Download is the average over the whole transfer; latency is the median of 10. Results vary run to run and with the distance to the nearest server. On metered or mobile data, Halo asks before starting.")), { info = false })
    confirm?.let { msg ->
        AlertDialog(onDismissRequest = { confirm = null }, containerColor = Halo.Background,
            title = { Text("Run on this connection?", color = Halo.Text) },
            text = { Text(msg, color = Halo.Text2) },
            confirmButton = { Button(onClick = { confirm = null; speed.start() }, modifier = Modifier.testTag("tools.speed.confirm")) { Text("Run anyway") } },
            dismissButton = { OutlinedButton(onClick = { confirm = null }) { Text("Cancel") } })
    }
}

@Composable
private fun Results(r: SpeedResult, atMs: Long) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
        HaloMetricTile("Down", r.downloadMbps?.let { "%.1f".format(it) }, "Mbps", Modifier.weight(1f).semantics { contentDescription = r.downloadMbps?.let { "Download: %.1f megabits per second".format(it) } ?: "Download: not measured" }.testTag("tools.speed.down"), Halo.Green)
        HaloMetricTile("Up", r.uploadMbps?.let { "%.1f".format(it) }, "Mbps", Modifier.weight(1f).semantics { contentDescription = r.uploadMbps?.let { "Upload: %.1f megabits per second".format(it) } ?: "Upload: not measured" }.testTag("tools.speed.up"), Halo.Accent)
        HaloMetricTile("Ping", r.latencyMs?.let { "%.0f".format(it) }, "ms", Modifier.weight(1f).semantics { contentDescription = r.latencyMs?.let { "Latency: %.0f milliseconds".format(it) } ?: "Latency: not measured" }.testTag("tools.speed.latency"), Halo.Amber)
    }
    r.problems.forEach { Text(it, color = Halo.Amber, fontSize = 12.sp, modifier = Modifier.testTag("tools.speed.problem")) }
    Text(DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(atMs)), color = Halo.Text3, fontSize = 11.sp)
}
