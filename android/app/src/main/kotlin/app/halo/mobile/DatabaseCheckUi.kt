package app.halo.mobile

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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import app.halo.cloud.CheckItem
import app.halo.cloud.CheckStatus
import app.halo.cloud.DatabaseCheck
import app.halo.cloud.DatabaseCheckReport
import app.halo.cloud.LiveDatabaseProbeTransport
import app.halo.mobile.cloud.CloudProfile
import app.halo.mobile.cloud.CloudViewModel
import app.halo.mobile.cloud.DebugEndpoints
import app.halo.mobile.design.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// F-057 FR-S1, phone side: "Check my database". The engine is in :halocloud (DatabaseCheck.kt, JVM-tested); this is the screen.
// It signs in with the stored credential and probes meta, devices, sms and clipboard. The report text contains no token,
// password or key (engine guarantee, tested). Reached from Home -> Quick actions -> "Check database" and Settings -> Halo cloud.

class DatabaseCheckViewModel : ViewModel() {
    var running by mutableStateOf(false); private set
    var report by mutableStateOf<DatabaseCheckReport?>(null); private set
    private var job: Job? = null

    fun run(profile: CloudProfile) {
        if (running) return
        running = true
        job = viewModelScope.launch {
            // try/finally: an unexpected exception must not leave the button disabled for good.
            try {
                report = withContext(Dispatchers.IO) {
                    val insecure = DebugEndpoints.applies(profile.config.databaseURL)
                    val transport = LiveDatabaseProbeTransport(profile.config, profile.auth, DebugEndpoints.auth(profile.config.databaseURL), insecure)
                    DatabaseCheck(transport, profile.config.databaseURL, insecure).run()
                }
            } finally { running = false }
        }
    }
}

@Composable
fun DatabaseCheckScreen(cloud: CloudViewModel, vm: DatabaseCheckViewModel = viewModel()) {
    val profile by cloud.profile.collectAsStateWithLifecycle()
    val p = profile
    // Opening the screen is the request: run once, unless a report is already on hand (rotation / coming back).
    LaunchedEffect(p != null) { if (p != null && vm.report == null) vm.run(p) }

    // The sub-screen bar already carries the title, so this is HaloScreen's rhythm without a second big heading.
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = HaloSpacing.ScreenH, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(HaloSpacing.Gap)) {
        Text("Can this phone read, write and delete?", style = HaloType.Caption, color = HaloColors.Text2)
        if (p == null) {
            HaloCard { HaloEmptyState(Icons.Filled.Lock, "Not connected", subtitle = "Pair with your Mac first") }
            return@Column
        }
        val r = vm.report
        val (tint, word, icon) = when {
            vm.running && r == null -> Triple(HaloColors.Accent, "Checking…", Icons.Filled.Refresh)
            r == null -> Triple(HaloColors.Text3, "Not checked", Icons.Filled.Refresh)
            r.overall == CheckStatus.PASS -> Triple(HaloColors.Green, "All good", Icons.Filled.CheckCircle)
            r.overall == CheckStatus.WARN -> Triple(HaloColors.Amber, "Works, fix soon", Icons.Filled.Warning)
            else -> Triple(HaloColors.Red, "Needs fixing", Icons.Filled.Close)
        }
        HaloCard(accentTop = tint) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                HaloIconBadge(icon, tint, size = 48.dp, iconSize = 26.dp)
                Column(Modifier.weight(1f)) {
                    Text(word, style = HaloType.Title, color = HaloColors.Text, modifier = Modifier.testTag("dbcheck.overall"))
                    Text(when (r?.overall) { CheckStatus.PASS -> "Every folder Halo uses works."; CheckStatus.WARN -> "Works, with something to fix."; CheckStatus.FAIL -> "Something needs fixing."; else -> "Probing meta, devices, sms, clipboard" },
                        style = HaloType.Caption, color = HaloColors.Text2)
                }
                HaloInfoButton(DB_INFO)
            }
            Spacer(Modifier.height(12.dp))
            HaloPrimaryButton(if (vm.running) "Checking…" else "Check again", { vm.run(p) }, Modifier.fillMaxWidth().testTag("dbcheck.run"), icon = Icons.Filled.Refresh, loading = vm.running)
        }
        if (r != null) {
            HaloSectionHeader("Results")
            HaloCard { r.items.forEach { CheckRow(it) } }
        }
    }
}

private val DB_INFO = HaloInfo("Check my database",
    "Tests that your Firebase database lets this phone read, write and delete under every folder Halo uses — before a sync fails.",
    listOf("It signs in with the saved credential and writes, reads back and deletes a small probe under each folder. The result never contains a token, password or key."))

private fun colorOf(s: CheckStatus) = when (s) { CheckStatus.PASS -> HaloColors.Green; CheckStatus.WARN -> HaloColors.Amber; CheckStatus.FAIL -> HaloColors.Red; CheckStatus.SKIPPED -> HaloColors.Text3 }
private fun iconOf(s: CheckStatus): ImageVector = when (s) { CheckStatus.PASS -> Icons.Filled.Check; CheckStatus.WARN -> Icons.Filled.Warning; CheckStatus.FAIL -> Icons.Filled.Close; CheckStatus.SKIPPED -> Icons.Filled.Refresh }
private fun wordOf(s: CheckStatus) = when (s) { CheckStatus.PASS -> "Pass"; CheckStatus.WARN -> "Warning"; CheckStatus.FAIL -> "Failed"; CheckStatus.SKIPPED -> "Skipped" }

@Composable
private fun CheckRow(i: CheckItem) {
    Row(verticalAlignment = Alignment.Top, modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp).testTag("dbcheck.row.${i.kind}")) {
        HaloIconBadge(iconOf(i.status), colorOf(i.status), size = 32.dp, iconSize = 18.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(i.title, color = HaloColors.Text, fontSize = 14.sp)
            Text(i.detail, color = HaloColors.Text2, fontSize = 12.sp)
            i.fix?.let { Spacer(Modifier.height(2.dp)); Text("Fix: $it", color = HaloColors.Amber, fontSize = 12.sp) }
        }
        Spacer(Modifier.width(8.dp))
        HaloStatusBadge(wordOf(i.status), colorOf(i.status))
    }
}
